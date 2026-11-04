import Foundation
import CoreServices

struct Entry {
    let path: String
    let key: [UInt8]     // normalized file name
    let stemLen: Int
    let isDir: Bool
    var alive = true
}

/// An in-memory index of every file name under the roots. It is built by a
/// parallel directory walk, then kept current by FSEvents, so it never depends
/// on Spotlight's database being complete.
final class FileIndex {
    let home = NSHomeDirectory()
    lazy var roots: [String] = {
        var r = [home, "/Applications"]
        for extra in ["\(home)/Library/Mobile Documents", "\(home)/Library/CloudStorage"]
            where FileManager.default.fileExists(atPath: extra) { r.append(extra) }
        return r
    }()

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var idByPath: [String: Int] = [:]
    private var scanning = false
    private var pendingEvents: [(String, FSEventStreamEventFlags)] = []
    private var stream: FSEventStreamRef?
    private let eventQueue = DispatchQueue(label: "seek.fsevents")

    var onChange: (() -> Void)?
    /// Paths created, modified, moved or deleted (from FSEvents). Called on a background queue.
    var onPathsChanged: (([String]) -> Void)?
    /// A full walk finished.
    var onScanComplete: (() -> Void)?
    var isScanning: Bool { lock.withLock { scanning } }
    var count: Int { lock.withLock { idByPath.count } }
    func snapshot() -> [Entry] { lock.withLock { entries } }

    // MARK: - What to index

    static let skipNames: Set<String> = ["node_modules", "site-packages", "__pycache__", "DerivedData",
                                         "Pods", "bower_components", ".Trash"]
    static let packageExts: Set<String> = ["app", "bundle", "framework", "photoslibrary", "musiclibrary",
                                           "tvlibrary", "photolibrary", "xcarchive", "xcodeproj",
                                           "xcworkspace", "playground", "rtfd", "pages", "numbers",
                                           "key", "logicx", "band", "fcpbundle", "plugin", "kext",
                                           "imovielibrary", "lrlibrary", "sparsebundle", "xpc"]

    /// Should the walker go *inside* this directory? (It is indexed either way.)
    func descendable(parent: String, name: String) -> Bool {
        if name.hasPrefix(".") || Self.skipNames.contains(name) { return false }
        if let dot = name.lastIndex(of: "."),
           Self.packageExts.contains(name[name.index(after: dot)...].lowercased()) { return false }
        if parent == home && name == "Library" { return false }  // cloud folders are their own roots
        return true
    }

    /// Would a full walk have produced this path? Used to filter FSEvents.
    func indexable(_ path: String) -> Bool {
        guard let root = roots.filter({ path.hasPrefix($0 + "/") }).max(by: { $0.count < $1.count })
        else { return false }
        let comps = path.dropFirst(root.count + 1).split(separator: "/").map(String.init)
        var parent = root
        for c in comps.dropLast() {
            if !descendable(parent: parent, name: c) { return false }
            parent += "/" + c
        }
        return true
    }

    // MARK: - Full scan

    func rescan() {
        lock.withLock { scanning = true; pendingEvents.removeAll() }
        DispatchQueue.main.async { self.onChange?() }

        let start = Date()
        let items = Walker(descend: descendable).run(roots: roots)
        let built = Self.build(items)

        lock.withLock {
            entries = built.0
            idByPath = built.1
            scanning = false
        }
        // Changes that happened while we were walking may be missing from the
        // fresh snapshot; FSEvents buffered them, so replay them now.
        let replay = lock.withLock { () -> [(String, FSEventStreamEventFlags)] in
            defer { pendingEvents.removeAll() }
            return pendingEvents
        }
        for (p, f) in replay { apply(p, f) }

        log("indexed \(built.1.count) items in \(String(format: "%.2f", Date().timeIntervalSince(start)))s")
        DispatchQueue.main.async { self.onChange?() }
        saveCache()
        onScanComplete?()
    }

    private static func build(_ items: [Walker.Item]) -> ([Entry], [String: Int]) {
        var keys = [[UInt8]](repeating: [], count: items.count)
        let chunks = ProcessInfo.processInfo.activeProcessorCount * 4
        let per = (items.count + chunks - 1) / max(chunks, 1)
        keys.withUnsafeMutableBufferPointer { kb in
            DispatchQueue.concurrentPerform(iterations: chunks) { c in
                let lo = c * per, hi = min(lo + per, items.count)
                guard lo < hi else { return }
                for i in lo..<hi {
                    kb[i] = Normalizer.key((items[i].path as NSString).lastPathComponent)
                }
            }
        }
        var entries = [Entry]()
        entries.reserveCapacity(items.count)
        var ids = [String: Int](minimumCapacity: items.count)
        for (i, it) in items.enumerated() where ids[it.path] == nil {
            ids[it.path] = entries.count
            entries.append(Entry(path: it.path, key: keys[i],
                                 stemLen: Normalizer.stemLength(keys[i], isDir: it.isDir), isDir: it.isDir))
        }
        return (entries, ids)
    }

    // MARK: - Incremental updates (FSEvents)

    func startWatching() {
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            let me = Unmanaged<FileIndex>.fromOpaque(info!).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as! [String]
            var batch: [(String, FSEventStreamEventFlags)] = []
            for i in 0..<count { batch.append((list[i], flags[i])) }
            me.handle(batch)
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes |
                                             kFSEventStreamCreateFlagFileEvents |
                                             kFSEventStreamCreateFlagWatchRoot)
        guard let s = FSEventStreamCreate(nil, cb, &ctx, roots as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                          0.3, flags) else { log("FSEvents unavailable"); return }
        FSEventStreamSetDispatchQueue(s, eventQueue)
        FSEventStreamStart(s)
        stream = s
    }

    private func handle(_ batch: [(String, FSEventStreamEventFlags)]) {
        lock.withLock { if scanning { pendingEvents += batch } }
        for (p, f) in batch { apply(p, f) }
        DispatchQueue.main.async { self.onChange?() }
    }

    private func apply(_ rawPath: String, _ flags: FSEventStreamEventFlags) {
        let path = rawPath.count > 1 && rawPath.hasSuffix("/") ? String(rawPath.dropLast()) : rawPath
        if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0 {
            let gone = remove(path, subtree: true)
            onPathsChanged?(gone + addSubtree(path))
            return
        }
        guard indexable(path) else { return }
        var st = stat()
        if lstat(path, &st) == 0 {
            let isDir = (st.st_mode & S_IFMT) == S_IFDIR
            let isNew = insert(path, isDir: isDir)
            // A directory that just appeared (created, or moved in) brings its whole subtree.
            var changed = [path]
            if isDir && isNew,
               descendable(parent: (path as NSString).deletingLastPathComponent,
                           name: (path as NSString).lastPathComponent) {
                changed += addSubtree(path)
            }
            onPathsChanged?(changed)
        } else {
            onPathsChanged?([path] + remove(path, subtree: true))
        }
    }

    @discardableResult
    private func insert(_ path: String, isDir: Bool) -> Bool {
        let k = Normalizer.key((path as NSString).lastPathComponent)
        return lock.withLock {
            if idByPath[path] != nil { return false }
            idByPath[path] = entries.count
            entries.append(Entry(path: path, key: k, stemLen: Normalizer.stemLength(k, isDir: isDir), isDir: isDir))
            return true
        }
    }

    private func addSubtree(_ dir: String) -> [String] {
        let items = Walker(descend: descendable).run(roots: [dir])
        for it in items { insert(it.path, isDir: it.isDir) }
        return items.map(\.path)
    }

    @discardableResult
    private func remove(_ path: String, subtree: Bool) -> [String] {
        lock.withLock {
            var doomed: [String] = []
            if idByPath[path] != nil { doomed.append(path) }
            if subtree {
                let prefix = path + "/"
                for p in idByPath.keys where p.hasPrefix(prefix) { doomed.append(p) }
            }
            for p in doomed { if let id = idByPath.removeValue(forKey: p) { entries[id].alive = false } }
            return doomed
        }
    }

    // MARK: - Cache (so search works instantly at launch, before the rescan finishes)

    static let supportDir: URL = {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Seek")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    private var cacheURL: URL { Self.supportDir.appendingPathComponent("index.cache") }

    func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL), let text = String(data: data, encoding: .utf8)
        else { return }
        var items: [Walker.Item] = []
        for line in text.split(separator: "\n") {
            if line.hasSuffix("/") { items.append(.init(path: String(line.dropLast()), isDir: true)) }
            else { items.append(.init(path: String(line), isDir: false)) }
        }
        let built = Self.build(items)
        lock.withLock { if entries.isEmpty { entries = built.0; idByPath = built.1 } }
        DispatchQueue.main.async { self.onChange?() }
    }

    private func saveCache() {
        let snap = snapshot()
        var out = ""
        out.reserveCapacity(snap.count * 80)
        for e in snap where e.alive && !e.path.contains("\n") {
            out += e.path; if e.isDir { out += "/" }; out += "\n"
        }
        try? out.data(using: .utf8)?.write(to: cacheURL, options: .atomic)
    }
}

/// Parallel directory walker: worker threads share a stack of directories, so
/// one deep folder (say, ~/Documents) doesn't leave the other cores idle.
/// Uses readdir's d_type, so it never stats a file.
final class Walker {
    struct Item { let path: String; let isDir: Bool }

    private var stack: [String] = []
    private var active = 0
    private let cond = NSCondition()
    private let descend: (String, String) -> Bool
    private var results: [Item] = []
    private let resultLock = NSLock()

    init(descend: @escaping (String, String) -> Bool) { self.descend = descend }

    func run(roots: [String]) -> [Item] {
        stack = roots
        let threads = max(4, ProcessInfo.processInfo.activeProcessorCount * 2)  // I/O-bound: oversubscribe
        DispatchQueue.concurrentPerform(iterations: threads) { _ in
            var local: [Item] = []
            while let dir = next() {
                scan(dir, into: &local)
                finish()
            }
            resultLock.withLock { results += local }
        }
        return results
    }

    private func next() -> String? {
        cond.lock(); defer { cond.unlock() }
        while stack.isEmpty && active > 0 { cond.wait() }
        guard let d = stack.popLast() else { cond.broadcast(); return nil }
        active += 1
        return d
    }

    private func finish() {
        cond.lock()
        active -= 1
        if active == 0 || !stack.isEmpty { cond.broadcast() }
        cond.unlock()
    }

    private func scan(_ dir: String, into local: inout [Item]) {
        guard let d = opendir(dir) else { return }
        defer { closedir(d) }
        var subdirs: [String] = []
        while let ent = readdir(d) {
            let name = withUnsafePointer(to: &ent.pointee.d_name) {
                String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
            }
            if name == "." || name == ".." { continue }
            let full = dir == "/" ? "/" + name : dir + "/" + name
            var isDir = ent.pointee.d_type == DT_DIR
            if ent.pointee.d_type == DT_UNKNOWN {
                var st = stat()
                isDir = lstat(full, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
            }
            local.append(Item(path: full, isDir: isDir))
            if isDir && descend(dir, name) { subdirs.append(full) }
        }
        if !subdirs.isEmpty {
            cond.lock(); stack += subdirs; cond.broadcast(); cond.unlock()
        }
    }
}

func log(_ s: String) { FileHandle.standardError.write(("[seek] " + s + "\n").data(using: .utf8)!) }
