import Foundation

/// Turns a file name or a query into one canonical byte form, so that what you
/// type and what is on disk compare equal even when their raw bytes differ:
///  - case-folded, diacritics stripped ("Café" == "cafe"; also fixes NFC vs NFD,
///    since APFS/HFS+ hand back decomposed names)
///  - every whitespace variant, `_` and `-` become one plain space (macOS
///    screenshots use U+202F before "PM"; this is why Finder misses them)
///  - runs of spaces collapsed, ends trimmed
enum Normalizer {
    static func key(_ s: String) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(s.utf8.count)
        var ascii = true
        for b in s.utf8 where b >= 0x80 { ascii = false; break }
        if ascii {
            for b in s.utf8 { push(b, &out) }
        } else {
            let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                   locale: nil).precomposedStringWithCanonicalMapping
            for sc in folded.unicodeScalars {
                if sc.isASCII { push(UInt8(sc.value), &out) }
                else if sc.properties.isWhitespace { push(32, &out) }
                else { UTF8.encode(sc) { out.append($0) } }
            }
        }
        while out.last == 32 { out.removeLast() }
        return out
    }

    @inline(__always) private static func push(_ b: UInt8, _ out: inout [UInt8]) {
        var c = b
        if c >= 65 && c <= 90 { c += 32 }
        if c == 95 || c == 45 || c == 9 || c == 10 || c == 13 { c = 32 }
        if c == 32 && (out.isEmpty || out.last == 32) { return }
        out.append(c)
    }

    /// Length of the name without its extension ("report.pdf" -> 6).
    static func stemLength(_ k: [UInt8], isDir: Bool) -> Int {
        if isDir { return k.count }
        var i = k.count - 1
        while i > 0 { if k[i] == 46 { return i }; i -= 1 }
        return k.count
    }
}

@inline(__always) func isAlnum(_ c: UInt8) -> Bool {
    (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c >= 0x80
}

struct Query {
    let full: [UInt8]       // normalized name part
    let tokens: [[UInt8]]   // split on spaces
    let compact: [UInt8]    // spaces removed, for fuzzy
    let dirFilter: [UInt8]? // text before the last "/", must appear in the parent path

    init?(_ text: String) {
        var name = text
        var dir: [UInt8]? = nil
        if let slash = text.lastIndex(of: "/") {
            let d = Normalizer.key(String(text[..<slash]))
            dir = d.isEmpty ? nil : d
            name = String(text[text.index(after: slash)...])
        }
        full = Normalizer.key(name)
        tokens = full.split(separator: 32).map(Array.init)
        compact = full.filter { $0 != 32 }
        dirFilter = dir
        if full.isEmpty && dir == nil { return nil }
    }
}

/// Match tiers. A higher tier always outranks a lower one; signals like
/// frecency only reorder results *within* a tier, so an exact-name match can
/// never be buried under a "popular" fuzzy match.
enum Tier: Int, Comparable {
    case none = 0, fuzzy, allTokens, substring, wordSubstring, prefix, exact
    static func < (a: Tier, b: Tier) -> Bool { a.rawValue < b.rawValue }
}

enum Matcher {
    /// Returns (tier, within-tier score). Pure byte work, no allocation.
    static func score(_ k: UnsafeBufferPointer<UInt8>, stemLen: Int, q: Query,
                      qf: UnsafeBufferPointer<UInt8>, qc: UnsafeBufferPointer<UInt8>) -> (Tier, Int) {
        let n = k.count, m = qf.count
        if m == 0 { return (.substring, 0) }  // only a dir filter was given
        if m > n { return fuzzyOrNone(k, q: q, qc: qc) }
        let coverage = m * 100 / max(n, 1)    // 0...100, prefers tighter names

        if hasPrefix(k, qf) {
            if m == n { return (.exact, 200) }             // "report.pdf" == "report.pdf"
            if m == stemLen { return (.exact, 150) }       // "report" == "report.pdf"
            return (.prefix, coverage)
        }
        if let pos = find(k, qf, from: 1) {
            let atWord = !isAlnum(k[pos - 1])
            return (atWord ? .wordSubstring : .substring, coverage - min(pos, 30))
        }
        if q.tokens.count > 1 {
            var all = true, boundaries = 0
            for t in q.tokens {
                let ok = t.withUnsafeBufferPointer { tb -> Bool in
                    guard let p = find(k, tb, from: 0) else { return false }
                    if p == 0 || !isAlnum(k[p - 1]) { boundaries += 1 }
                    return true
                }
                if !ok { all = false; break }
            }
            if all { return (.allTokens, coverage + boundaries * 20) }
        }
        return fuzzyOrNone(k, q: q, qc: qc)
    }

    /// Greedy subsequence match with bonuses for word starts and runs.
    /// Rejects matches spread so thin they are noise.
    @inline(__always)
    static func fuzzyOrNone(_ k: UnsafeBufferPointer<UInt8>, q: Query, qc: UnsafeBufferPointer<UInt8>) -> (Tier, Int) {
        let m = qc.count
        if m < 3 || m > k.count { return (.none, 0) }
        var qi = 0, score = 0, last = -2, first = -1
        var i = 0
        while i < k.count && qi < m {
            if k[i] == qc[qi] {
                if first < 0 { first = i }
                if i == last + 1 { score += 8 }
                if i == 0 || !isAlnum(k[i - 1]) { score += 10 }
                score += 2
                last = i; qi += 1
            }
            i += 1
        }
        if qi < m { return (.none, 0) }
        let span = last - first + 1
        if span > m * 3 + 3 { return (.none, 0) }
        return (.fuzzy, score - (span - m) * 2 - first)
    }

    @inline(__always)
    static func hasPrefix(_ k: UnsafeBufferPointer<UInt8>, _ p: UnsafeBufferPointer<UInt8>) -> Bool {
        if p.count > k.count { return false }
        for i in 0..<p.count where k[i] != p[i] { return false }
        return true
    }

    @inline(__always)
    static func find(_ k: UnsafeBufferPointer<UInt8>, _ p: UnsafeBufferPointer<UInt8>, from: Int) -> Int? {
        let n = k.count, m = p.count
        if m == 0 || m > n { return nil }
        let first = p[0]
        var i = from
        while i <= n - m {
            if k[i] == first {
                var j = 1
                while j < m && k[i + j] == p[j] { j += 1 }
                if j == m { return i }
            }
            i += 1
        }
        return nil
    }

    /// Substring test over the normalized parent path (for "cs2200/hw3" queries).
    static func pathContains(_ path: String, _ needle: [UInt8]) -> Bool {
        let parent = (path as NSString).deletingLastPathComponent
        let k = Normalizer.key(parent)
        return k.withUnsafeBufferPointer { kb in
            needle.withUnsafeBufferPointer { nb in find(kb, nb, from: 0) != nil }
        }
    }
}
