import AppKit

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class SearchPanel: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    let searcher: Searcher
    let panel: KeyPanel
    private let field = NSTextField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let footer = NSTextField(labelWithString: "")
    private var results: [SearchResult] = []
    private var iconCache: [String: NSImage] = [:]
    private let queue = DispatchQueue(label: "seek.search", qos: .userInteractive, attributes: .concurrent)
    private var lastQueryTime: Double = 0

    init(searcher: Searcher) {
        self.searcher = searcher
        panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
                         styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        super.init()
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        [.closeButton, .miniaturizeButton, .zoomButton].forEach { panel.standardWindowButton($0)?.isHidden = true }
        panel.delegate = self
        build()
    }

    private func build() {
        let bg = NSVisualEffectView()
        bg.material = .popover
        bg.state = .active
        bg.blendingMode = .behindWindow
        panel.contentView = bg

        field.placeholderString = "Search files by name…   (dir/name to filter by folder)"
        field.font = .systemFont(ofSize: 22, weight: .light)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.cell?.usesSingleLineMode = true

        let col = NSTableColumn(identifier: .init("c"))
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 40
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.backgroundColor = .clear
        table.style = .inset
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)

        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true

        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .secondaryLabelColor
        footer.lineBreakMode = .byTruncatingMiddle

        let sep = NSBox(); sep.boxType = .separator
        for v in [field, sep, scroll, footer] { v.translatesAutoresizingMaskIntoConstraints = false; bg.addSubview(v) }
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: bg.topAnchor, constant: 18),
            field.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 20),
            field.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -20),
            sep.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 12),
            sep.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: sep.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -4),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -6),
            footer.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 16),
            footer.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -16),
            footer.bottomAnchor.constraint(equalTo: bg.bottomAnchor, constant: -10),
        ])
        refreshFooter()
    }

    // MARK: - Show / hide

    func toggle() { panel.isVisible ? hide() : show() }

    func show() {
        captureFinderContext()
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let f = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: f.midX - panel.frame.width / 2, y: f.minY + f.height * 0.62 - panel.frame.height / 2))
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        if !field.stringValue.isEmpty { runQuery() }
        refreshFooter()
    }

    func hide() { panel.orderOut(nil) }
    func windowDidResignKey(_ notification: Notification) { hide() }

    /// If you summoned Seek from Finder, results inside that window's folder rank higher.
    private func captureFinderContext() {
        searcher.contextFolder = nil
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" else { return }
        let src = """
        tell application "Finder"
            if (count of Finder windows) > 0 then return POSIX path of (target of front Finder window as alias)
        end tell
        """
        var err: NSDictionary?
        if let path = NSAppleScript(source: src)?.executeAndReturnError(&err).stringValue {
            searcher.contextFolder = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        }
    }

    func refreshFooter() {
        let idx = searcher.index
        var parts: [String] = []
        parts.append(idx.isScanning ? "Indexing… \(idx.count.formatted()) so far" : "\(idx.count.formatted()) items")
        if !results.isEmpty { parts.append(String(format: "%.1f ms", lastQueryTime)) }
        if let c = searcher.contextFolder { parts.append("boosting \(abbrev(c))") }
        parts.append("↩ open   ⌘↩ show in Finder   ⌥↩ copy path")
        footer.stringValue = parts.joined(separator: "   ·   ")
    }

    // MARK: - Query

    func controlTextDidChange(_ obj: Notification) { runQuery() }

    private func runQuery() {
        let text = field.stringValue
        queue.async { [weak self] in
            guard let self else { return }
            let t0 = CFAbsoluteTimeGetCurrent()
            guard let r = self.searcher.search(text) else { return }  // nil = superseded
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            DispatchQueue.main.async {
                guard self.field.stringValue == text else { return }
                self.results = r
                self.lastQueryTime = ms
                self.table.reloadData()
                if !r.isEmpty { self.table.selectRowIndexes([0], byExtendingSelection: false); self.table.scrollRowToVisible(0) }
                self.refreshFooter()
            }
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)): move(1); return true
        case #selector(NSResponder.moveUp(_:)): move(-1); return true
        case #selector(NSResponder.cancelOperation(_:)): hide(); return true
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            let mods = NSApp.currentEvent?.modifierFlags ?? []
            activate(mods.contains(.command) ? .reveal : mods.contains(.option) ? .copy : .open)
            return true
        default: return false
        }
    }

    private func move(_ d: Int) {
        guard !results.isEmpty else { return }
        let r = max(0, min(results.count - 1, table.selectedRow + d))
        table.selectRowIndexes([r], byExtendingSelection: false)
        table.scrollRowToVisible(r)
    }

    private enum Action { case open, reveal, copy }

    @objc private func doubleClicked() { activate(.open) }

    private func activate(_ a: Action) {
        let row = table.selectedRow
        guard row >= 0 && row < results.count else { return }
        let path = results[row].path
        searcher.frecency.record(path)
        let url = URL(fileURLWithPath: path)
        switch a {
        case .open: NSWorkspace.shared.open(url)
        case .reveal: NSWorkspace.shared.activateFileViewerSelecting([url])
        case .copy:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(path, forType: .string)
        }
        hide()
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: ResultCell.id, owner: nil) as? ResultCell) ?? ResultCell()
        let r = results[row]
        cell.name.stringValue = (r.path as NSString).lastPathComponent
        cell.path.stringValue = abbrev((r.path as NSString).deletingLastPathComponent)
        cell.icon.image = icon(r.path)
        return cell
    }

    private func icon(_ path: String) -> NSImage {
        if let i = iconCache[path] { return i }
        let i = NSWorkspace.shared.icon(forFile: path)
        if iconCache.count > 2000 { iconCache.removeAll() }
        iconCache[path] = i
        return i
    }

    private func abbrev(_ p: String) -> String {
        let h = searcher.index.home
        return p.hasPrefix(h) ? "~" + p.dropFirst(h.count) : p
    }
}

final class ResultCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("ResultCell")
    let icon = NSImageView()
    let name = NSTextField(labelWithString: "")
    let path = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        name.font = .systemFont(ofSize: 14, weight: .medium)
        name.lineBreakMode = .byTruncatingMiddle
        path.font = .systemFont(ofSize: 11)
        path.textColor = .secondaryLabelColor
        path.lineBreakMode = .byTruncatingMiddle
        for v in [icon, name, path] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 28),
            icon.heightAnchor.constraint(equalToConstant: 28),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            name.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            name.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            path.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            path.trailingAnchor.constraint(equalTo: name.trailingAnchor),
            path.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 1),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}
