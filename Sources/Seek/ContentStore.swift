import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Persistent full-text index of file contents, backed by SQLite FTS5.
///
/// FTS5 keeps an inverted index (term -> postings list of documents) and ranks
/// with BM25, so a query costs time proportional to the postings it touches,
/// not to the number of files. Two connections in WAL mode let the indexer
/// write while searches read a consistent snapshot without blocking.
final class ContentStore {
    struct Hit { let path: String; let score: Double; let snippet: String }
    struct Stamp { let id: Int64; let mtime: Double; let size: Int64 }

    private var writer: OpaquePointer?
    private var reader: OpaquePointer?
    private let readLock = NSLock()
    private let writeLock = NSLock()

    init(url: URL) {
        sqlite3_open_v2(url.path, &writer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil)
        exec(writer, """
            PRAGMA journal_mode=WAL;
            PRAGMA synchronous=NORMAL;
            CREATE TABLE IF NOT EXISTS docs(
                id INTEGER PRIMARY KEY, path TEXT UNIQUE NOT NULL,
                mtime REAL NOT NULL, size INTEGER NOT NULL, kind INTEGER NOT NULL);
            CREATE VIRTUAL TABLE IF NOT EXISTS fts USING fts5(
                name, body, tokenize='unicode61 remove_diacritics 2', prefix='2 3');
            CREATE TABLE IF NOT EXISTS vecs(doc INTEGER NOT NULL, v BLOB NOT NULL);
            CREATE INDEX IF NOT EXISTS vecs_doc ON vecs(doc);
            CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
            """)
        sqlite3_busy_timeout(writer, 2000)
        sqlite3_open_v2(url.path, &reader, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        sqlite3_busy_timeout(reader, 2000)
    }

    deinit { sqlite3_close(writer); sqlite3_close(reader) }

    // MARK: - Writes

    /// Groups many writes into one transaction (one fsync instead of hundreds).
    func transaction(_ body: () -> Void) {
        writeLock.withLock {
            exec(writer, "BEGIN")
            body()
            exec(writer, "COMMIT")
        }
    }

    /// Insert or replace a document. Call inside `transaction`. Returns its id.
    @discardableResult
    func upsert(path: String, mtime: Double, size: Int64, kind: Int, body: String) -> Int64 {
        removeUnlocked(path)
        let name = (path as NSString).lastPathComponent
        let ins = prepare(writer, "INSERT INTO docs(path, mtime, size, kind) VALUES(?,?,?,?)")
        bind(ins, 1, path); sqlite3_bind_double(ins, 2, mtime); sqlite3_bind_int64(ins, 3, size)
        sqlite3_bind_int(ins, 4, Int32(kind))
        sqlite3_step(ins); sqlite3_finalize(ins)
        let id = sqlite3_last_insert_rowid(writer)
        let f = prepare(writer, "INSERT INTO fts(rowid, name, body) VALUES(?,?,?)")
        sqlite3_bind_int64(f, 1, id); bind(f, 2, name); bind(f, 3, body)
        sqlite3_step(f); sqlite3_finalize(f)
        return id
    }

    /// Call inside `transaction`. Returns the removed id, if any.
    @discardableResult
    func remove(_ path: String) -> Int64? { removeUnlocked(path) }

    private func removeUnlocked(_ path: String) -> Int64? {
        let q = prepare(writer, "SELECT id FROM docs WHERE path = ?")
        bind(q, 1, path)
        guard sqlite3_step(q) == SQLITE_ROW else { sqlite3_finalize(q); return nil }
        let id = sqlite3_column_int64(q, 0)
        sqlite3_finalize(q)
        for sql in ["DELETE FROM fts WHERE rowid = ?", "DELETE FROM docs WHERE id = ?", "DELETE FROM vecs WHERE doc = ?"] {
            let d = prepare(writer, sql); sqlite3_bind_int64(d, 1, id); sqlite3_step(d); sqlite3_finalize(d)
        }
        return id
    }

    /// Vectors from different models live in different spaces and can't be
    /// compared, so switching models throws the old ones away.
    func useEmbeddingModel(_ name: String) {
        writeLock.withLock {
            let q = prepare(writer, "SELECT value FROM meta WHERE key = 'embedding_model'")
            let current = sqlite3_step(q) == SQLITE_ROW ? text(q, 0) : nil
            sqlite3_finalize(q)
            guard current != name else { return }
            exec(writer, "DELETE FROM vecs")
            let u = prepare(writer, "INSERT OR REPLACE INTO meta(key, value) VALUES('embedding_model', ?)")
            bind(u, 1, name); sqlite3_step(u); sqlite3_finalize(u)
            log("semantic: embedding model is now \(name); re-embedding")
        }
    }

    /// Store a document's vector. nil is stored as an empty blob, meaning
    /// "embedded, nothing usable", so it isn't retried. Call inside `transaction`.
    func setVector(doc: Int64, _ v: [Float]?) {
        let ins = prepare(writer, "INSERT INTO vecs(doc, v) VALUES(?, ?)")
        defer { sqlite3_finalize(ins) }
        sqlite3_bind_int64(ins, 1, doc)
        let bytes = v ?? []
        bytes.withUnsafeBytes { _ = sqlite3_bind_blob(ins, 2, $0.baseAddress ?? UnsafeRawPointer(bitPattern: 1), Int32($0.count), SQLITE_TRANSIENT) }
        sqlite3_step(ins)
    }

    // MARK: - Reads

    /// Documents with text but no vectors yet, newest first.
    func missingVectors(limit: Int) -> [(id: Int64, path: String, body: String)] {
        readLock.withLock {
            let q = prepare(reader, """
                SELECT d.id, d.path, f.body FROM docs d JOIN fts f ON f.rowid = d.id
                WHERE length(f.body) >= 40 AND NOT EXISTS (SELECT 1 FROM vecs v WHERE v.doc = d.id)
                ORDER BY d.kind, d.mtime DESC LIMIT ?
                """)
            sqlite3_bind_int(q, 1, Int32(limit))
            var out: [(Int64, String, String)] = []
            while sqlite3_step(q) == SQLITE_ROW { out.append((sqlite3_column_int64(q, 0), text(q, 1), text(q, 2))) }
            sqlite3_finalize(q)
            return out
        }
    }

    /// Every stored document vector of width `dim`.
    func allVectors(dim: Int) -> [(doc: Int64, path: String, vector: [Float])] {
        readLock.withLock {
            let q = prepare(reader, "SELECT v.doc, d.path, v.v FROM vecs v JOIN docs d ON d.id = v.doc")
            var out: [(Int64, String, [Float])] = []
            while sqlite3_step(q) == SQLITE_ROW {
                guard Int(sqlite3_column_bytes(q, 2)) == dim * 4, let p = sqlite3_column_blob(q, 2) else { continue }
                let v = Array(UnsafeBufferPointer(start: p.assumingMemoryBound(to: Float.self), count: dim))
                out.append((sqlite3_column_int64(q, 0), text(q, 1), v))
            }
            sqlite3_finalize(q)
            return out
        }
    }

    /// path -> (id, mtime, size) for every indexed document, for change detection.
    func stamps() -> [String: Stamp] {
        readLock.withLock {
            var out: [String: Stamp] = [:]
            let q = prepare(reader, "SELECT path, id, mtime, size FROM docs")
            while sqlite3_step(q) == SQLITE_ROW {
                out[text(q, 0)] = Stamp(id: sqlite3_column_int64(q, 1), mtime: sqlite3_column_double(q, 2),
                                        size: sqlite3_column_int64(q, 3))
            }
            sqlite3_finalize(q)
            return out
        }
    }

    /// The stored extracted text of one file (for the evidence pane).
    func body(path: String) -> String? {
        readLock.withLock {
            let q = prepare(reader, "SELECT f.body FROM docs d JOIN fts f ON f.rowid = d.id WHERE d.path = ?")
            defer { sqlite3_finalize(q) }
            bind(q, 1, path)
            return sqlite3_step(q) == SQLITE_ROW ? text(q, 0) : nil
        }
    }

    /// Documents of a kind whose text was actually read (e.g. images with OCR text).
    func countWithText(kind: Int) -> Int {
        readLock.withLock {
            let q = prepare(reader, "SELECT count(*) FROM docs d JOIN fts f ON f.rowid = d.id WHERE d.kind = ? AND length(f.body) > 0")
            defer { sqlite3_finalize(q) }
            sqlite3_bind_int(q, 1, Int32(kind))
            return sqlite3_step(q) == SQLITE_ROW ? Int(sqlite3_column_int64(q, 0)) : 0
        }
    }

    var count: Int {
        readLock.withLock {
            let q = prepare(reader, "SELECT count(*) FROM docs")
            defer { sqlite3_finalize(q) }
            return sqlite3_step(q) == SQLITE_ROW ? Int(sqlite3_column_int64(q, 0)) : 0
        }
    }

    /// BM25-ranked search. Every word must appear; the last word is matched as
    /// a prefix so results appear while you are still typing it. Snippets are
    /// built only for the first `snippets` hits (the rows you can actually see).
    func search(_ text: String, limit: Int = 60, snippets: Int = 10) -> [Hit] {
        let words = Self.terms(text)
        guard !words.isEmpty, words.joined().count >= 2 else { return [] }
        let match = words.enumerated().map { i, w in
            let quoted = "\"" + w.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            return i == words.count - 1 && w.count >= 2 ? quoted + "*" : quoted
        }.joined(separator: " ")
        // BM25 scores each word independently, so "func search" ranks a file full of
        // both words above the one that literally says `func search(`. Exact-phrase
        // matches therefore go first (last word still a prefix), then everything else.
        let phrase = words.count >= 2
            ? "\"" + words.joined(separator: " ").replacingOccurrences(of: "\"", with: "\"\"") + "\""
              + (words.last!.count >= 2 ? "*" : "")
            : nil
        return readLock.withLock {
            // Ranking walks only the postings lists of the query terms: sub-millisecond.
            // bm25 weights: a hit in the file name counts 3x a hit in the body.
            func ranked(_ m: String) -> [(String, Int64, Double)] {
                let q = prepare(reader, """
                    SELECT d.path, f.rowid, f.score FROM
                        (SELECT rowid, bm25(fts, 3.0, 1.0) AS score FROM fts WHERE fts MATCH ? ORDER BY score LIMIT ?) f
                    JOIN docs d ON d.id = f.rowid ORDER BY f.score
                    """)
                defer { sqlite3_finalize(q) }
                bind(q, 1, m); sqlite3_bind_int(q, 2, Int32(limit))
                var out: [(String, Int64, Double)] = []
                while sqlite3_step(q) == SQLITE_ROW {
                    out.append((self.text(q, 0), sqlite3_column_int64(q, 1), -sqlite3_column_double(q, 2)))
                }
                return out
            }
            var rows = phrase.map(ranked) ?? []
            let inPhrase = Set(rows.map(\.1))
            let top = rows.first?.2 ?? 0
            rows = rows.map { ($0.0, $0.1, $0.2 + top) }   // keep phrase hits strictly above the rest
            rows += ranked(match).filter { !inPhrase.contains($0.1) }
            rows = Array(rows.prefix(limit))

            // FTS5's snippet() re-tokenizes the whole document (up to 200 KB), which
            // costs more than the search itself. A plain substring scan is far cheaper.
            // Pull only the head of each body into Swift; most matches are early.
            let head = prepare(reader, "SELECT substr(body, 1, 20000) FROM fts WHERE rowid = ?")
            let full = prepare(reader, "SELECT body FROM fts WHERE rowid = ?")
            defer { sqlite3_finalize(head); sqlite3_finalize(full) }
            func fetch(_ st: OpaquePointer?, _ id: Int64) -> String {
                sqlite3_reset(st); sqlite3_bind_int64(st, 1, id)
                return sqlite3_step(st) == SQLITE_ROW ? self.text(st, 0) : ""
            }
            return rows.enumerated().map { i, r in
                var snip = ""
                if i < snippets {
                    snip = Self.snippet(fetch(head, r.1), words)
                    if snip.isEmpty { snip = Self.snippet(fetch(full, r.1), words) }
                }
                return Hit(path: r.0, score: r.2, snippet: snip)
            }
        }
    }

    /// ~120 characters around the first query word, with every word wrapped in
    /// \u{1}…\u{2} markers for highlighting.
    static func snippet(_ body: String, _ words: [String]) -> String {
        let ns = body as NSString
        let opts: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        var first = NSRange(location: NSNotFound, length: 0)
        for w in words where w.count >= 2 || words.count == 1 {
            let r = ns.range(of: w, options: opts)
            if r.location != NSNotFound && (first.location == NSNotFound || r.location < first.location) { first = r }
        }
        guard first.location != NSNotFound else { return "" }
        let lo = max(0, first.location - 40)
        let hi = min(ns.length, first.location + 90)
        var window = ns.substring(with: NSRange(location: lo, length: hi - lo))
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        for w in words.sorted(by: { $0.count > $1.count }) where w.count >= 2 {
            var out = "", rest = window[...]
            while let r = rest.range(of: w, options: opts) {
                out += rest[..<r.lowerBound] + "\u{1}" + rest[r] + "\u{2}"
                rest = rest[r.upperBound...]
            }
            window = out + rest
        }
        return (lo > 0 ? "…" : "") + window + (hi < ns.length ? "…" : "")
    }

    /// Splits a query into FTS terms the same way the unicode61 tokenizer does.
    static func terms(_ s: String) -> [String] {
        s.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init)
    }

    // MARK: - SQLite helpers

    private func exec(_ db: OpaquePointer?, _ sql: String) {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK, let err {
            log("sqlite: \(String(cString: err))"); sqlite3_free(err)
        }
    }

    private func prepare(_ db: OpaquePointer?, _ sql: String) -> OpaquePointer? {
        var s: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &s, nil) != SQLITE_OK {
            log("sqlite prepare: \(String(cString: sqlite3_errmsg(db)))")
        }
        return s
    }

    private func bind(_ s: OpaquePointer?, _ i: Int32, _ v: String) { sqlite3_bind_text(s, i, v, -1, SQLITE_TRANSIENT) }

    private func text(_ s: OpaquePointer?, _ i: Int32) -> String {
        guard let c = sqlite3_column_text(s, i) else { return "" }
        return String(cString: c)
    }
}
