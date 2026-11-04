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
        for sql in ["DELETE FROM fts WHERE rowid = ?", "DELETE FROM docs WHERE id = ?"] {
            let d = prepare(writer, sql); sqlite3_bind_int64(d, 1, id); sqlite3_step(d); sqlite3_finalize(d)
        }
        return id
    }

    // MARK: - Reads

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

    var count: Int {
        readLock.withLock {
            let q = prepare(reader, "SELECT count(*) FROM docs")
            defer { sqlite3_finalize(q) }
            return sqlite3_step(q) == SQLITE_ROW ? Int(sqlite3_column_int64(q, 0)) : 0
        }
    }

    /// BM25-ranked search. Every word must appear; the last word is matched as
    /// a prefix so results appear while you are still typing it.
    func search(_ text: String, limit: Int = 60) -> [Hit] {
        let words = Self.terms(text)
        guard !words.isEmpty else { return [] }
        let match = words.enumerated().map { i, w in
            let quoted = "\"" + w.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            return i == words.count - 1 && w.count >= 2 ? quoted + "*" : quoted
        }.joined(separator: " ")
        return readLock.withLock {
            // bm25 weights: a hit in the file name counts 3x a hit in the body.
            let q = prepare(reader, """
                SELECT d.path, bm25(fts, 3.0, 1.0), snippet(fts, 1, char(1), char(2), '…', 14)
                FROM fts JOIN docs d ON d.id = fts.rowid
                WHERE fts MATCH ? ORDER BY bm25(fts, 3.0, 1.0) LIMIT ?
                """)
            bind(q, 1, match); sqlite3_bind_int(q, 2, Int32(limit))
            var hits: [Hit] = []
            while sqlite3_step(q) == SQLITE_ROW {
                hits.append(Hit(path: self.text(q, 0), score: -sqlite3_column_double(q, 1), snippet: self.text(q, 2)))
            }
            sqlite3_finalize(q)
            return hits
        }
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
