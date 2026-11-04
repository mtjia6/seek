import AppKit
import Carbon

// CLI mode for testing:  Seek --query "exact file name"
let args = CommandLine.arguments
if let qi = args.firstIndex(of: "--query"), qi + 1 < args.count {
    let index = FileIndex()
    let t0 = Date()
    index.rescan()
    let scanTime = Date().timeIntervalSince(t0)
    let searcher = Searcher(index: index)
    for q in args[(qi + 1)...] {
        let t1 = CFAbsoluteTimeGetCurrent()
        let r = searcher.search(q) ?? []
        let ms = (CFAbsoluteTimeGetCurrent() - t1) * 1000
        print("── \"\(q)\"  \(r.count) results in \(String(format: "%.1f", ms)) ms")
        for x in r.prefix(8) { print("  [\(x.tier)] \(x.path)") }
    }
    print("index: \(index.count) items, scan \(String(format: "%.2f", scanTime))s")
    exit(0)
}

// Content search test:  Seek --content "words in a file" ...
if let ci = args.firstIndex(of: "--content"), ci + 1 < args.count {
    let index = FileIndex()
    let content = ContentIndexer(files: index)
    index.rescan()
    let t0 = Date()
    let done = DispatchSemaphore(value: 0)
    content.fullSync { done.signal() }
    done.wait()
    print("content index: \(content.indexedCount) docs, sync \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
    for q in args[(ci + 1)...] {
        var hits: [ContentStore.Hit] = [], ms = Double.infinity
        for _ in 0..<5 {  // best of 5: steady-state latency, not cold-cache
            let t1 = CFAbsoluteTimeGetCurrent()
            hits = content.store.search(q)
            ms = min(ms, (CFAbsoluteTimeGetCurrent() - t1) * 1000)
        }
        print("── \"\(q)\"  \(hits.count) hits in \(String(format: "%.1f", ms)) ms")
        for h in hits.prefix(5) {
            let snip = h.snippet.replacingOccurrences(of: "\u{1}", with: "[").replacingOccurrences(of: "\u{2}", with: "]")
                .replacingOccurrences(of: "\n", with: " ")
            print("  \(h.path)\n      \(snip.prefix(140))")
        }
    }
    if args.contains("--semantic") {
        print("semantic: \(content.vectors.rows) document vectors")
        for q in args[(ci + 1)...] where q != "--semantic" {
            var hits: [(path: String, score: Float)] = [], ms = Double.infinity
            for _ in 0..<5 {
                let t1 = CFAbsoluteTimeGetCurrent()
                hits = content.semanticSearch(q, minScore: 0)
                ms = min(ms, (CFAbsoluteTimeGetCurrent() - t1) * 1000)
            }
            print("≈≈ \"\(q)\"  \(String(format: "%.1f", ms)) ms")
            for h in hits.prefix(5) { print(String(format: "  %.3f  ", h.score) + h.path) }
        }
    }
    if args.contains("--hybrid") {
        let s = Searcher(index: index, content: content)
        for q in args[(ci + 1)...] where !q.hasPrefix("--") {
            var r: [SearchResult] = [], ms = Double.infinity
            for _ in 0..<5 {
                let t1 = CFAbsoluteTimeGetCurrent()
                r = s.search(q) ?? []
                ms = min(ms, (CFAbsoluteTimeGetCurrent() - t1) * 1000)
            }
            print("⊕ \"\(q)\" [\(Searcher.route(q))]  \(String(format: "%.1f", ms)) ms")
            for x in r.prefix(5) {
                let src = [x.sources.contains(.name) ? "name" : nil, x.sources.contains(.content) ? "text" : nil,
                           x.sources.contains(.meaning) ? "meaning" : nil].compactMap { $0 }.joined(separator: "+")
                print("  [\(x.tier == .exact ? "EXACT" : src)] \((x.path as NSString).lastPathComponent)")
            }
        }
    }
    exit(0)
}

// Live-update self-test:  Seek --watch-test
if args.contains("--watch-test") {
    let index = FileIndex()
    let content = ContentIndexer(files: index)
    index.onPathsChanged = { content.pathsChanged($0) }
    index.startWatching(); index.rescan()
    let s = Searcher(index: index)
    let dir = NSHomeDirectory() + "/Documents/seek_watch_test_dir"
    let fm = FileManager.default
    func check(_ q: String, _ label: String) {
        Thread.sleep(forTimeInterval: 1.0)
        let hits = (s.search(q) ?? []).filter { $0.tier == .exact }.map(\.path)
        print("\(label): \(hits.isEmpty ? "—" : hits.joined(separator: ", "))")
    }
    try? fm.createDirectory(atPath: dir + "/inner", withIntermediateDirectories: true)
    fm.createFile(atPath: dir + "/inner/zebra quokka.txt", contents: Data("the word is xylophonist".utf8))
    check("zebra quokka", "after create      ")
    func checkContent(_ q: String, _ label: String) {
        Thread.sleep(forTimeInterval: 1.5)
        let hits = content.store.search(q).map(\.path)
        print("\(label): \(hits.isEmpty ? "—" : hits.joined(separator: ", "))")
    }
    checkContent("xylophonist", "content indexed   ")
    try? Data("now it says marimbaist".utf8).write(to: URL(fileURLWithPath: dir + "/inner/zebra quokka.txt"))
    checkContent("xylophonist", "old content gone  "); checkContent("marimbaist", "edit reindexed    ")
    try? fm.moveItem(atPath: dir + "/inner/zebra quokka.txt", toPath: dir + "/inner/narwhal.txt")
    check("zebra quokka", "old name gone     "); check("narwhal", "new name found    ")
    try? fm.moveItem(atPath: dir, toPath: dir + "_moved")
    check("narwhal", "dir moved         ")
    checkContent("marimbaist", "content follows mv")
    try? fm.removeItem(atPath: dir + "_moved")
    check("narwhal", "dir deleted       ")
    checkContent("marimbaist", "content deleted   ")
    exit(0)
}

/// Global hotkey via Carbon; needs no Accessibility permission.
final class HotKey {
    private var ref: EventHotKeyRef?
    private static var action: (() -> Void)?

    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        HotKey.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.action?() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x5345_454B), id: 1)  // 'SEEK'
        guard RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr else { return nil }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let index = FileIndex()
    lazy var content = ContentIndexer(files: index)
    lazy var searcher = Searcher(index: index, content: content)
    lazy var panel = SearchPanel(searcher: searcher)
    var status: NSStatusItem!
    var hotKey: HotKey?
    var hotKeyLabel = "⌥Space"

    func applicationDidFinishLaunching(_ n: Notification) {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "doc.text.magnifyingglass", accessibilityDescription: "Seek")

        hotKey = HotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey)) { [weak self] in self?.panel.toggle() }
        if hotKey == nil {
            hotKeyLabel = "⌃⌥Space"
            hotKey = HotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey | controlKey)) { [weak self] in self?.panel.toggle() }
        }

        index.onChange = { [weak self] in self?.panel.refreshFooter(); self?.rebuildMenu() }
        let content = self.content
        content.onProgress = { [weak self] in self?.rebuildMenu() }
        index.onPathsChanged = { content.pathsChanged($0) }
        index.onScanComplete = { content.fullSync() }
        rebuildMenu()

        DispatchQueue.global(qos: .userInitiated).async { [index] in
            index.startWatching()   // start first, so nothing changed during the walk is lost
            index.loadCache()
            index.rescan()
        }
    }

    func rebuildMenu() {
        let m = NSMenu()
        m.addItem(withTitle: "Search Files…  (\(hotKeyLabel))", action: #selector(showPanel), keyEquivalent: "").target = self
        m.addItem(.separator())
        let info = NSMenuItem(title: index.isScanning ? "Indexing… \(index.count.formatted())" : "\(index.count.formatted()) items indexed",
                              action: nil, keyEquivalent: "")
        info.isEnabled = false
        m.addItem(info)
        let q = content.queuedCount
        let ci = NSMenuItem(title: q > 0 ? "Reading contents… \(q.formatted()) left" : "Contents indexed",
                            action: nil, keyEquivalent: "")
        ci.isEnabled = false
        m.addItem(ci)
        m.addItem(withTitle: "Rebuild Index", action: #selector(rebuild), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "Quit Seek", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        status.menu = m
    }

    @objc func showPanel() { panel.show() }
    @objc func rebuild() { DispatchQueue.global(qos: .userInitiated).async { [index] in index.rescan() } }
}

let app = NSApplication.shared
// Developer aid for screenshots: SEEK_APPEARANCE=light|dark forces the appearance.
switch ProcessInfo.processInfo.environment["SEEK_APPEARANCE"] {
case "light": app.appearance = NSAppearance(named: .aqua)
case "dark": app.appearance = NSAppearance(named: .darkAqua)
default: break
}
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
