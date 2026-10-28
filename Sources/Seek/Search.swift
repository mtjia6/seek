import Foundation

struct SearchResult {
    let path: String
    let isDir: Bool
    let tier: Tier
    let score: Int
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
    let frecency = Frecency()
    /// Folder of the front Finder window when the panel opened (boosted).
    var contextFolder: String?
    private let gen = Generation()

    init(index: FileIndex) { self.index = index }

    func search(_ text: String, limit: Int = 60) -> [SearchResult]? {
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
