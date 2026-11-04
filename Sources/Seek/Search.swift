import Foundation

struct SearchResult {
    let path: String
    let isDir: Bool
    let tier: Tier
    let score: Int
    var snippet: String? = nil
    var sources: Sources = .name
    /// How strongly each retriever matched, 0...1, for the match meter.
    var signal = Signal()

    struct Signal { var name: Float = 0, text: Float = 0, meaning: Float = 0 }

    struct Sources: OptionSet {
        let rawValue: Int
        static let name = Sources(rawValue: 1), content = Sources(rawValue: 2), meaning = Sources(rawValue: 4)
    }
}

/// Remembers which results you actually open, so ties break toward your files.
final class Frecency {
    private struct Rec: Codable { var count: Double; var last: Date }
    private var recs: [String: Rec] = [:]
    private let lock = NSLock()
    private let url = FileIndex.supportDir.appendingPathComponent("frecency.json")

    init() {
        if let d = try? Data(contentsOf: url), let r = try? JSONDecoder().decode([String: Rec].self, from: d) { recs = r }
    }

    func record(_ path: String) {
        lock.withLock {
            var r = recs[path] ?? Rec(count: 0, last: .distantPast)
            r.count += 1; r.last = Date()
            recs[path] = r
            if let d = try? JSONEncoder().encode(recs) { try? d.write(to: url, options: .atomic) }
        }
    }

    /// Most recently opened paths that still exist.
    func recent(limit: Int) -> [String] {
        let sorted = lock.withLock { recs.sorted { $0.value.last > $1.value.last }.map(\.key) }
        return Array(sorted.lazy.filter { FileManager.default.fileExists(atPath: $0) }.prefix(limit))
    }

    /// 0...300. log-count, halving every 2 weeks since last open.
    func bonus(_ path: String) -> Int {
        lock.withLock {
            guard let r = recs[path] else { return 0 }
            let days = Date().timeIntervalSince(r.last) / 86400
            return min(300, Int(120 * log2(1 + r.count) * pow(0.5, days / 14)))
        }
    }
}

final class Searcher {
    let index: FileIndex
    let content: ContentIndexer?
    let frecency = Frecency()
    /// Folder of the front Finder window when the panel opened (boosted).
    var contextFolder: String?
    private let gen = Generation()

    let activity: Activity

    init(index: FileIndex, content: ContentIndexer? = nil) {
        self.index = index; self.content = content
        activity = Activity(index: index)
    }

    // MARK: - Date filter

    /// `changed:today`, `changed:yesterday`, `changed:mon`…`changed:sun` (the most
    /// recent such day), or `changed:2026-10-30`. Any other words narrow it further.
    static func parseChanged(_ text: String) -> (range: Range<Date>, rest: String)? {
        var rest: [Substring] = []
        var range: Range<Date>?
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        for w in text.split(separator: " ") {
            guard w.lowercased().hasPrefix("changed:") else { rest.append(w); continue }
            let v = w.dropFirst("changed:".count).lowercased()
            var day: Date?
            if v == "today" { day = today }
            else if v == "yesterday" { day = cal.date(byAdding: .day, value: -1, to: today) }
            else if let i = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"].firstIndex(where: { v.hasPrefix($0) }) {
                let back = (cal.component(.weekday, from: today) - 1 - i + 7) % 7
                day = cal.date(byAdding: .day, value: -back, to: today)
            } else {
                let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
                day = f.date(from: String(v)).map { cal.startOfDay(for: $0) }
            }
            if let d = day, let end = cal.date(byAdding: .day, value: 1, to: d) { range = d..<end }
        }
        guard let range else { return nil }
        return (range, rest.joined(separator: " "))
    }

    private func changedSearch(_ range: Range<Date>, rest: String, limit: Int) -> [SearchResult]? {
        let inDay = activity.files(in: range).filter { !$0.path.contains("/.") }
        if rest.trimmingCharacters(in: .whitespaces).isEmpty {
            return inDay.prefix(limit).map { SearchResult(path: $0.path, isDir: false, tier: .none, score: 0, sources: []) }
        }
        let keep = Set(inDay.map(\.path))
        guard let r = search(rest, limit: 400) else { return nil }
        return Array(r.filter { keep.contains($0.path) }.prefix(limit))
    }

    // MARK: - Hybrid search

    /// What kind of query this looks like decides how much each retriever is trusted.
    enum Route { case name, word, general, question }

    static let stopwords: Set<String> = ["the", "a", "an", "of", "to", "in", "on", "for", "about", "how", "what",
                                         "why", "when", "where", "which", "with", "my", "that", "is", "are", "does", "do"]

    static func route(_ text: String) -> Route {
        let words = text.lowercased().split(separator: " ")
        if words.count == 1, text.contains(where: { "._/".contains($0) }) || text.contains(where: \.isUppercase) && text.contains(where: \.isLowercase) && text.first?.isLowercase == true {
            return .name                                         // report.pdf, file_index, myFunc
        }
        if words.count >= 4 || words.contains(where: { stopwords.contains(String($0)) }) { return .question }
        return words.count == 1 ? .word : .general           // one bare word is usually a name lookup
    }

    /// Name matches, BM25 content matches and semantic matches, run concurrently
    /// and merged with Reciprocal Rank Fusion: score = sum over lists of w / (k + rank).
    /// RRF uses ranks, not raw scores, so lists whose scores live on different
    /// scales (tiers, BM25, cosine) combine without calibration, and a file that
    /// shows up in several lists rises. Exact-name matches are pinned above it all.
    func search(_ text: String, limit: Int = 60) -> [SearchResult]? {
        if text.lowercased().contains("changed:"), let c = Self.parseChanged(text) {
            return changedSearch(c.range, rest: c.rest, limit: limit)
        }
        guard let content else { return nameSearch(text, limit: limit) }
        var names: [SearchResult]? = nil
        var hits: [ContentStore.Hit] = []
        var meaning: [(path: String, score: Float)] = []
        DispatchQueue.concurrentPerform(iterations: 3) { i in
            switch i {
            case 0: names = nameSearch(text, limit: 100)
            case 1: hits = content.store.search(text, limit: 60, snippets: 20)
            default: meaning = content.semanticSearch(text, k: 40)
            }
        }
        guard let names else { return nil }  // superseded by a newer keystroke

        let (wName, wText, wMeaning): (Double, Double, Double)
        switch Self.route(text) {
        case .name: (wName, wText, wMeaning) = (1.4, 0.8, 0.5)
        case .word: (wName, wText, wMeaning) = (1.3, 0.9, 0.6)
        case .general: (wName, wText, wMeaning) = (1.0, 1.0, 0.9)
        case .question: (wName, wText, wMeaning) = (0.7, 1.0, 1.5)
        }
        let k = 60.0
        var fused: [String: (score: Double, r: SearchResult)] = [:]
        func add(_ path: String, _ w: Double, _ rank: Int, _ make: () -> SearchResult, _ merge: (inout SearchResult) -> Void) {
            if var cur = fused[path] {
                merge(&cur.r); cur.score += w / (k + Double(rank)); fused[path] = cur
            } else {
                var r = make(); merge(&r); fused[path] = (w / (k + Double(rank)), r)
            }
        }
        let pinnedPaths = names.filter { $0.tier == .exact }.map(\.path)
        let topText = Float(hits.first?.score ?? 1)
        for (rank, r) in names.enumerated() {
            add(r.path, wName, rank + 1, { r }, { $0.signal.name = Self.nameStrength(r.tier) })
        }
        for (rank, h) in hits.enumerated() {
            add(h.path, wText, rank + 1,
                { SearchResult(path: h.path, isDir: false, tier: .none, score: 0, sources: []) },
                { r in
                    r.sources.insert(.content)
                    if !h.snippet.isEmpty { r.snippet = h.snippet }
                    r.signal.text = max(0.15, min(1, Float(h.score) / max(topText, 1e-6)))   // BM25 relative to best
                })
        }
        for (rank, m) in meaning.enumerated() {
            // A file found *only* by meaning needs a confident match to be shown at all.
            if fused[m.path] == nil && m.score < 0.42 { continue }
            add(m.path, wMeaning, rank + 1,
                { SearchResult(path: m.path, isDir: false, tier: .none, score: 0, sources: []) },
                { r in
                    r.sources.insert(.meaning)
                    r.signal.meaning = max(0.1, min(1, (m.score - 0.3) / 0.35))           // cosine 0.3...0.65
                })
        }
        // Signals from the name ranker still apply: frecency and the Finder folder.
        for (p, v) in fused {
            var bonus = Double(frecency.bonus(p)) / 300 * 0.004
            if let ctx = contextFolder, p.hasPrefix(ctx + "/") { bonus += 0.002 }
            fused[p] = (v.score + bonus, v.r)
        }
        // Exact names first (in name order, now carrying every signal), then the fused rest.
        let pinned = pinnedPaths.compactMap { fused[$0]?.r }
        let pinnedSet = Set(pinnedPaths)
        var rest = fused.values.filter { !pinnedSet.contains($0.r.path) }.sorted { $0.score > $1.score }.map(\.r)
        // Content and meaning hits come from the database; drop any deleted since.
        rest = rest.filter { r in r.sources.contains(.name) || FileManager.default.fileExists(atPath: r.path) }
        return Array((pinned + rest).prefix(limit))
    }

    /// Name-match strength by tier: how literally the name matched what you typed.
    static func nameStrength(_ t: Tier) -> Float {
        switch t {
        case .exact: return 1
        case .prefix: return 0.8
        case .wordSubstring: return 0.65
        case .substring: return 0.5
        case .allTokens: return 0.45
        case .fuzzy: return 0.3
        case .none: return 0
        }
    }

    // MARK: - Name search

    func nameSearch(_ text: String, limit: Int = 60) -> [SearchResult]? {
        guard let q = Query(text) else { return [] }
        let myGen = gen.bump()
        let snap = index.snapshot()
        let chunks = ProcessInfo.processInfo.activeProcessorCount * 4
        let per = (snap.count + chunks - 1) / max(chunks, 1)
        var partials = [[(Int, Tier, Int)]](repeating: [], count: chunks)
        let keepPerChunk = 400

        q.full.withUnsafeBufferPointer { qf in
            q.compact.withUnsafeBufferPointer { qc in
                snap.withUnsafeBufferPointer { eb in
                    partials.withUnsafeMutableBufferPointer { pb in
                        DispatchQueue.concurrentPerform(iterations: chunks) { c in
                            let lo = c * per, hi = min(lo + per, eb.count)
                            guard lo < hi else { return }
                            var local: [(Int, Tier, Int)] = []
                            for i in lo..<hi {
                                if (i & 4095) == 0 && gen.current != myGen { return }  // superseded by newer keystroke
                                let e = eb[i]
                                guard e.alive else { continue }
                                let (tier, s) = e.key.withUnsafeBufferPointer {
                                    Matcher.score($0, stemLen: e.stemLen, q: q, qf: qf, qc: qc)
                                }
                                if tier == .none { continue }
                                if let d = q.dirFilter, !Matcher.pathContains(e.path, d) { continue }
                                local.append((i, tier, s))
                                if local.count > keepPerChunk * 8 { Self.trim(&local, keepPerChunk) }
                            }
                            Self.trim(&local, keepPerChunk)
                            pb[c] = local
                        }
                    }
                }
            }
        }
        if gen.current != myGen { return nil }

        // Re-rank the survivors with signals that are too costly to compute for every file.
        var merged = partials.flatMap { $0 }
        Self.trim(&merged, 400)
        let now = Date().timeIntervalSince1970
        var ranked: [SearchResult] = merged.map { (i, tier, base) in
            let e = snap[i]
            var s = base * 4 + frecency.bonus(e.path)
            if let ctx = contextFolder, e.path.hasPrefix(ctx + "/") { s += 150 }
            var st = stat()
            if stat(e.path, &st) == 0 {
                let ageDays = (now - Double(st.st_mtimespec.tv_sec)) / 86400
                s += max(0, 60 - Int(ageDays * 2))                     // recently touched
            } else { return SearchResult(path: e.path, isDir: e.isDir, tier: .none, score: 0) }  // deleted
            if e.path.hasPrefix(index.home + "/Library/") { s -= 40 }
            if e.path.contains("/.") { s -= 80 }
            s -= min(60, e.path.split(separator: "/").count * 3)        // shallower first
            return SearchResult(path: e.path, isDir: e.isDir, tier: tier, score: s)
        }
        ranked.removeAll { $0.tier == .none }
        ranked.sort { $0.tier != $1.tier ? $0.tier > $1.tier : $0.score > $1.score }
        return Array(ranked.prefix(limit))
    }

    private static func trim(_ a: inout [(Int, Tier, Int)], _ k: Int) {
        guard a.count > k else { return }
        a.sort { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 > $1.2 }
        a.removeLast(a.count - k)
    }
}

/// Modification times for every indexed file, for the home screen's activity
/// chart and `changed:` queries. One parallel stat pass (~20 ms for 20k files),
/// cached for two minutes.
final class Activity {
    private let index: FileIndex
    private let lock = NSLock()
    private var cache: [(path: String, mtime: Date)] = []
    private var built = Date.distantPast

    init(index: FileIndex) { self.index = index }

    func all() -> [(path: String, mtime: Date)] {
        if let c = lock.withLock({ Date().timeIntervalSince(built) < 120 && !cache.isEmpty ? cache : nil }) { return c }
        let snap = index.snapshot().filter { $0.alive && !$0.isDir && !$0.path.hasPrefix("/Applications/") }
        var times = [Double](repeating: 0, count: snap.count)
        times.withUnsafeMutableBufferPointer { tb in
            DispatchQueue.concurrentPerform(iterations: 16) { c in
                var i = c
                while i < snap.count {
                    var st = stat()
                    if lstat(snap[i].path, &st) == 0 { tb[i] = Double(st.st_mtimespec.tv_sec) }
                    i += 16
                }
            }
        }
        var out: [(String, Date)] = []
        out.reserveCapacity(snap.count)
        for (e, t) in zip(snap, times) where t > 0 { out.append((e.path, Date(timeIntervalSince1970: t))) }
        out.sort { $0.1 > $1.1 }
        lock.withLock { cache = out; built = Date() }
        return out
    }

    func files(in range: Range<Date>) -> [(path: String, mtime: Date)] { all().filter { range.contains($0.mtime) } }

    /// Files changed per calendar day, oldest first, ending today.
    func perDay(days: Int) -> [(day: Date, count: Int)] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var counts = [Int](repeating: 0, count: days)
        for f in all() {
            let d = cal.dateComponents([.day], from: cal.startOfDay(for: f.mtime), to: today).day ?? Int.max
            if d >= 0 && d < days { counts[days - 1 - d] += 1 } else if d >= days { break }  // sorted newest first
        }
        return (0..<days).map { (cal.date(byAdding: .day, value: $0 - days + 1, to: today)!, counts[$0]) }
    }
}

final class Generation {
    private var value = 0
    private let lock = NSLock()
    var current: Int { lock.withLock { value } }
    func bump() -> Int { lock.withLock { value += 1; return value } }
}
