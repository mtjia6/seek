import Foundation

struct SearchResult {
    let path: String
    let isDir: Bool
    let tier: Tier
    let score: Int
    var snippet: String? = nil
    var sources: Sources = .name

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

    init(index: FileIndex, content: ContentIndexer? = nil) { self.index = index; self.content = content }

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
        let pinned = names.filter { $0.tier == .exact }
        let pinnedPaths = Set(pinned.map(\.path))
        for (rank, r) in names.enumerated() where !pinnedPaths.contains(r.path) {
            add(r.path, wName, rank + 1, { r }, { _ in })
        }
        for (rank, h) in hits.enumerated() where !pinnedPaths.contains(h.path) {
            add(h.path, wText, rank + 1,
                { SearchResult(path: h.path, isDir: false, tier: .none, score: 0, sources: []) },
                { $0.sources.insert(.content); if !h.snippet.isEmpty { $0.snippet = h.snippet } })
        }
        for (rank, m) in meaning.enumerated() where !pinnedPaths.contains(m.path) {
            // A file found *only* by meaning needs a confident match to be shown at all.
            if fused[m.path] == nil && m.score < 0.42 { continue }
            add(m.path, wMeaning, rank + 1,
                { SearchResult(path: m.path, isDir: false, tier: .none, score: 0, sources: []) },
                { $0.sources.insert(.meaning) })
        }
        // Signals from the name ranker still apply: frecency and the Finder folder.
        for (p, v) in fused {
            var bonus = Double(frecency.bonus(p)) / 300 * 0.004
            if let ctx = contextFolder, p.hasPrefix(ctx + "/") { bonus += 0.002 }
            fused[p] = (v.score + bonus, v.r)
        }
        var rest = fused.values.sorted { $0.score > $1.score }.map(\.r)
        // Content and meaning hits come from the database; drop any deleted since.
        rest = rest.filter { r in r.sources.contains(.name) || FileManager.default.fileExists(atPath: r.path) }
        return Array((pinned + rest).prefix(limit))
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

final class Generation {
    private var value = 0
    private let lock = NSLock()
    var current: Int { lock.withLock { value } }
    func bump() -> Int { lock.withLock { value += 1; return value } }
}
