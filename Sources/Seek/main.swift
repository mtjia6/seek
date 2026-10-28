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
    lazy var searcher = Searcher(index: index)
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
        m.addItem(withTitle: "Rebuild Index", action: #selector(rebuild), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "Quit Seek", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        status.menu = m
    }

    @objc func showPanel() { panel.show() }
    @objc func rebuild() { DispatchQueue.global(qos: .userInitiated).async { [index] in index.rescan() } }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
