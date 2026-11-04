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
    }

    struct Job { let path: String; let kind: ContentKind; let mtime: Double; let size: Int64 }

    // MARK: - Full reconciliation (after each full file scan)

    func fullSync(completion: (() -> Void)? = nil) {
        queue.async { [self] in
            stamps = store.stamps()
            var jobs: [Job] = []
            var live = Set<String>()
            for e in files.snapshot() where e.alive && !e.isDir {
                guard let kind = Extractor.kind(for: e.path) else { continue }
                live.insert(e.path)
                if let j = job(e.path, kind) { jobs.append(j) }
            }
            // Files deleted while Seek wasn't running.
            let gone = stamps.keys.filter { !live.contains($0) }
            if !gone.isEmpty {
                store.transaction { for p in gone { store.remove(p) } }
                for p in gone { stamps[p] = nil }
            }
            // Cheap kinds first, newest files first within a kind: useful results arrive soonest.
            jobs.sort { $0.kind.rawValue != $1.kind.rawValue ? $0.kind.rawValue < $1.kind.rawValue : $0.mtime > $1.mtime }
            log("content: \(stamps.count) up to date, \(jobs.count) to index, \(gone.count) removed")
            run(jobs)
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
        if !removed.isEmpty {
            store.transaction { for p in removed { store.remove(p) } }
            for p in removed { stamps[p] = nil }
        }
        run(jobs)
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
}
