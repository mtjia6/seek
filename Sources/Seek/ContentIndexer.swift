import Foundation

/// Keeps the content store in sync with the file index.
///
/// Extraction is the expensive part (PDF parsing, later OCR), so each file is
/// read once and remembered by (mtime, size). After that, only files FSEvents
/// reports as changed are looked at again. All bookkeeping happens on one
/// serial queue; extraction itself fans out across cores.
final class ContentIndexer {
    let store: ContentStore
    let files: FileIndex
    let embedder = Embedder()
    let vectors: VectorIndex
    var onProgress: (() -> Void)?

    private let queue = DispatchQueue(label: "seek.content", qos: .utility)
    private var stamps: [String: ContentStore.Stamp] = [:]   // queue-confined
    private var dirty = Set<String>()
    private var flushScheduled = false
    private let dirtyLock = NSLock()
    private let progressLock = NSLock()
    private var _queued = 0

    var indexedCount: Int { store.count }
    var queuedCount: Int { progressLock.withLock { _queued } }

    init(files: FileIndex) {
        self.files = files
        store = ContentStore(url: FileIndex.supportDir.appendingPathComponent("content.sqlite"))
        vectors = VectorIndex(dim: embedder.dim)
        if embedder.available { store.useEmbeddingModel(Embedder.modelName) }
    }

    /// Documents whose meaning is close to the query, even with no shared words.
    func semanticSearch(_ text: String, k: Int = 30, minScore: Float = 0.3) -> [(path: String, score: Float)] {
        guard text.split(separator: " ").count >= 2 || text.count >= 8,
              let q = embedder.vector(text) else { return [] }
        return vectors.search(q, k: k, minScore: minScore)
    }

    struct Job { let path: String; let kind: ContentKind; let mtime: Double; let size: Int64 }

    // MARK: - Full reconciliation (after each full file scan)

    func fullSync(completion: (() -> Void)? = nil) {
        queue.async { [self] in
            stamps = store.stamps()
            if vectors.rows == 0 {
                for d in store.allVectors(dim: embedder.dim) { vectors.add(doc: d.doc, path: d.path, vector: d.vector) }
                log("semantic: loaded \(vectors.rows) document vectors")
            }
            var jobs: [Job] = []
            var live = Set<String>()
            for e in files.snapshot() where e.alive && !e.isDir {
                guard let kind = Extractor.kind(for: e.path) else { continue }
                live.insert(e.path)
                if let j = job(e.path, kind) { jobs.append(j) }
            }
            // Files deleted while Seek wasn't running.
            let gone = stamps.keys.filter { !live.contains($0) }
            if !gone.isEmpty { removeDocs(gone) }
            // Cheap kinds first, newest files first within a kind: useful results arrive soonest.
            jobs.sort { $0.kind.rawValue != $1.kind.rawValue ? $0.kind.rawValue < $1.kind.rawValue : $0.mtime > $1.mtime }
            log("content: \(stamps.count) up to date, \(jobs.count) to index, \(gone.count) removed")
            run(jobs)
            embedMissing()
            completion?()
        }
    }

    /// A job if the file needs (re)indexing, nil if it is unchanged or not eligible.
    private func job(_ path: String, _ kind: ContentKind) -> Job? {
        var st = stat()
        guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        let mtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
        let size = Int64(st.st_size)
        guard Extractor.sizeAllowed(kind, size) else { return nil }
        if let s = stamps[path], s.mtime == mtime, s.size == size { return nil }
        return Job(path: path, kind: kind, mtime: mtime, size: size)
    }

    // MARK: - Incremental updates

    func pathsChanged(_ paths: [String]) {
        let schedule = dirtyLock.withLock { () -> Bool in
            dirty.formUnion(paths)
            defer { flushScheduled = true }
            return !flushScheduled
        }
        // Coalesce bursts (an editor saving, a git checkout) into one pass.
        if schedule { queue.asyncAfter(deadline: .now() + 1.0) { [self] in flush() } }
    }

    private func flush() {
        let paths = dirtyLock.withLock { () -> Set<String> in
            defer { dirty.removeAll(); flushScheduled = false }
            return dirty
        }
        var jobs: [Job] = [], removed: [String] = []
        for p in paths {
            if let kind = Extractor.kind(for: p), files.indexable(p), FileManager.default.fileExists(atPath: p) {
                if let j = job(p, kind) { jobs.append(j) }
            } else if stamps[p] != nil {
                removed.append(p)
            }
        }
        if !removed.isEmpty { removeDocs(removed) }
        run(jobs)
        embedMissing()
    }

    private func removeDocs(_ paths: [String]) {
        store.transaction {
            for p in paths { if let id = store.remove(p) { vectors.remove(doc: id) } }
        }
        for p in paths { stamps[p] = nil }
    }

    // MARK: - Extraction pipeline

    private func run(_ jobs: [Job]) {
        guard !jobs.isEmpty else { return }
        progressLock.withLock { _queued += jobs.count }
        let width = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)  // leave cores for you
        var i = 0
        while i < jobs.count {
            let batch = Array(jobs[i..<min(i + 48, jobs.count)])
            var texts = [String?](repeating: nil, count: batch.count)
            texts.withUnsafeMutableBufferPointer { tb in
                DispatchQueue.concurrentPerform(iterations: width) { w in
                    var k = w
                    while k < batch.count {
                        autoreleasepool { tb[k] = Extractor.extract(batch[k].path, batch[k].kind) }
                        k += width
                    }
                }
            }
            store.transaction {
                for (j, text) in zip(batch, texts) {
                    // Store failures too (empty body) so they aren't retried on every launch.
                    if let old = stamps[j.path] { vectors.remove(doc: old.id) }
                    let id = store.upsert(path: j.path, mtime: j.mtime, size: j.size, kind: j.kind.rawValue,
                                          body: text ?? "")
                    stamps[j.path] = .init(id: id, mtime: j.mtime, size: j.size)
                }
            }
            progressLock.withLock { _queued -= batch.count }
            DispatchQueue.main.async { self.onProgress?() }
            i += batch.count
        }
    }

    /// Second pass: embed every document that has text but no vector (new,
    /// changed, or indexed before semantic search existed). ~0.7 ms per doc.
    private func embedMissing() {
        guard embedder.available else { return }
        while true {
            let batch = store.missingVectors(limit: 256)
            if batch.isEmpty { return }
            progressLock.withLock { _queued += batch.count }
            var out = [[Float]?](repeating: nil, count: batch.count)
            out.withUnsafeMutableBufferPointer { ob in
                DispatchQueue.concurrentPerform(iterations: batch.count) { k in
                    let name = (batch[k].path as NSString).lastPathComponent
                    ob[k] = Embedder.passage(name: name, body: batch[k].body).flatMap(embedder.vector)
                }
            }
            store.transaction { for (d, v) in zip(batch, out) { store.setVector(doc: d.id, v) } }
            for (d, v) in zip(batch, out) { if let v { vectors.add(doc: d.id, path: d.path, vector: v) } }
            progressLock.withLock { _queued -= batch.count }
            DispatchQueue.main.async { self.onProgress?() }
        }
    }
}
