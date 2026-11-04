import AppKit
import Quartz

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    // Quick Look asks the responder chain who will feed it; the panel answers.
    weak var previewSource: (QLPreviewPanelDataSource & QLPreviewPanelDelegate)?
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { previewSource != nil }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = previewSource; panel.delegate = previewSource
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = nil; panel.delegate = nil }
}

final class SearchPanel: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate,
                         QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    let searcher: Searcher
    let panel: KeyPanel
    private let field = NSTextField()
    private let glass = NSImageView()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let separator = NSBox()
    private let status = NSTextField(labelWithString: "")
    private let hints = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "")
    private var results: [SearchResult] = []
    private var showingRecents = false
    private var iconCache: [String: NSImage] = [:]
    private let queue = DispatchQueue(label: "seek.search", qos: .userInteractive)
    private var searching = false        // main-thread only
    private var pendingText: String?     // newest query typed while one was running
    private var lastQueryTime: Double = 0
    private var keyMonitor: Any?

    private let width: CGFloat = 760
    private let headerHeight: CGFloat = 64
    private let footerHeight: CGFloat = 34
    private let maxListHeight: CGFloat = 470

    init(searcher: Searcher) {
        self.searcher = searcher
        panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 64),
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
        panel.previewSource = self
        build()
    }

    private func build() {
        let bg = NSVisualEffectView()
        bg.material = .popover
        bg.state = .active
        bg.blendingMode = .behindWindow
        panel.contentView = bg

        glass.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        glass.symbolConfiguration = .init(pointSize: 20, weight: .regular)
        glass.contentTintColor = .secondaryLabelColor

        field.placeholderString = "Search names, contents, screenshots — or describe the file"
        field.font = .systemFont(ofSize: 22, weight: .light)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.cell?.usesSingleLineMode = true
        field.cell?.lineBreakMode = .byTruncatingTail

        table.addTableColumn(NSTableColumn(identifier: .init("c")))
        table.headerView = nil
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
        scroll.scrollerStyle = .overlay

        separator.boxType = .separator

        status.font = .systemFont(ofSize: 11)
        status.textColor = .tertiaryLabelColor
        status.lineBreakMode = .byTruncatingMiddle
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hints.attributedStringValue = Self.keyHints([("↩", "open"), ("⌘↩", "show in Finder"), ("⌘Y", "preview"),
                                                    ("⌥↩", "copy path")])
        hints.alignment = .right
        hints.setContentCompressionResistancePriority(.required, for: .horizontal)

        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center

        for v in [glass, field, separator, scroll, status, hints, emptyLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false; bg.addSubview(v)
        }
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 20),
            glass.centerYAnchor.constraint(equalTo: bg.topAnchor, constant: headerHeight / 2),
            field.leadingAnchor.constraint(equalTo: glass.trailingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -20),
            field.centerYAnchor.constraint(equalTo: glass.centerYAnchor),
            separator.topAnchor.constraint(equalTo: bg.topAnchor, constant: headerHeight),
            separator.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 2),
            scroll.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -2),
            scroll.bottomAnchor.constraint(equalTo: bg.bottomAnchor, constant: -footerHeight),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            status.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 18),
            status.centerYAnchor.constraint(equalTo: bg.bottomAnchor, constant: -footerHeight / 2),
            hints.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -18),
            hints.centerYAnchor.constraint(equalTo: status.centerYAnchor),
            hints.leadingAnchor.constraint(greaterThanOrEqualTo: status.trailingAnchor, constant: 12),
        ])
        refreshFooter()
    }

    /// "↩ open   ⌘↩ show in Finder" with the keys drawn as small caps.
    private static func keyHints(_ pairs: [(String, String)]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let key: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
                                                  .foregroundColor: NSColor.labelColor.withAlphaComponent(0.7),
                                                  .backgroundColor: NSColor.labelColor.withAlphaComponent(0.08)]
        let label: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11),
                                                    .foregroundColor: NSColor.secondaryLabelColor]
        for (i, (k, l)) in pairs.enumerated() {
            if i > 0 { out.append(NSAttributedString(string: "     ", attributes: label)) }
            out.append(NSAttributedString(string: " \(k) ", attributes: key))
            out.append(NSAttributedString(string: " \(l)", attributes: label))
        }
        return out
    }

    // MARK: - Show / hide

    func toggle() { panel.isVisible ? hide() : show() }

    func show() {
        captureFinderContext()
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let f = screen?.visibleFrame {
            let h = panel.frame.height
            panel.setFrameOrigin(NSPoint(x: f.midX - width / 2, y: f.minY + f.height * 0.72 - h))
        }
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
        installKeyMonitor()
        runQuery()
        refreshFooter()
    }

    func hide() {
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().orderOut(nil) }
        panel.orderOut(nil)
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }

    func windowDidResignKey(_ notification: Notification) {
        // Quick Look takes key status while previewing; that isn't "leaving Seek".
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { return }
        hide()
    }

    /// ⌘1–⌘9 open a result, ⌘Y toggles Quick Look. A local monitor sees these
    /// before the field editor swallows them.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  let ch = e.charactersIgnoringModifiers else { return e }
            if ch == "y" { self.togglePreview(); return nil }
            if let n = Int(ch), (1...9).contains(n), n <= self.results.count {
                self.table.selectRowIndexes([n - 1], byExtendingSelection: false)
                self.activate(.open)
                return nil
            }
            return e
        }
    }

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
        if idx.isScanning { parts.append("Indexing names… \(idx.count.formatted())") }
        else { parts.append("\(idx.count.formatted()) files") }
        if let c = searcher.content {
            let q = c.queuedCount
            parts.append(q > 0 ? "reading contents… \(q.formatted()) left" : "\(c.indexedCount.formatted()) with contents")
        }
        if !results.isEmpty && !showingRecents { parts.append(String(format: "%.1f ms", lastQueryTime)) }
        if let c = searcher.contextFolder { parts.append("boosting \(abbrev(c))") }
        status.stringValue = parts.joined(separator: "  ·  ")
    }

    // MARK: - Query

    func controlTextDidChange(_ obj: Notification) { runQuery() }

    /// Latest-wins: at most one search runs; keystrokes that arrive meanwhile
    /// collapse into a single follow-up search for the newest text. Running
    /// every keystroke's search at once made them compete for the same cores,
    /// and each one ran ~10x slower than alone.
    private func runQuery() {
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { pendingText = nil; showRecents(); return }
        if searching { pendingText = text; return }
        searching = true
        queue.async { [weak self] in
            guard let self else { return }
            let t0 = CFAbsoluteTimeGetCurrent()
            let r = self.searcher.search(text)
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            DispatchQueue.main.async {
                self.searching = false
                if let next = self.pendingText {
                    self.pendingText = nil
                    if next != text { self.runQuery(); return }
                }
                guard let r, self.field.stringValue.trimmingCharacters(in: .whitespaces) == text else { return }
                self.lastQueryTime = ms
                self.display(r, recents: false)
            }
        }
    }

    /// With an empty query, show what you opened recently instead of a blank box.
    private func showRecents() {
        let recent = searcher.frecency.recent(limit: 8).map {
            SearchResult(path: $0, isDir: Self.isDirectory($0), tier: .none, score: 0)
        }
        display(recent, recents: true)
    }

    private func display(_ r: [SearchResult], recents: Bool) {
        results = r
        showingRecents = recents
        table.reloadData()
        if !r.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false); table.scrollRowToVisible(0) }
        let hasQuery = !field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
        emptyLabel.stringValue = hasQuery ? "No matches" : ""
        emptyLabel.isHidden = !(hasQuery && r.isEmpty)
        resize()
        refreshFooter()
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().reloadData() }
        if let out = ProcessInfo.processInfo.environment["SEEK_SNAPSHOT"] { snapshot(to: out) }
    }

    /// Fit the panel to its content, keeping the search field where it is.
    private func resize() {
        let hasQuery = !field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
        var list: CGFloat = 0
        if !results.isEmpty {
            for i in 0..<results.count { list += tableView(table, heightOfRow: i) + 2 }
            list = min(list + 8, maxListHeight)
        } else if hasQuery {
            list = 90   // room for "No matches"
        }
        let showList = list > 0
        separator.isHidden = !showList
        scroll.isHidden = !showList
        status.isHidden = !showList
        hints.isHidden = !showList
        let h = headerHeight + (showList ? list + footerHeight : 0)
        var f = panel.frame
        guard abs(f.height - h) > 0.5 else { return }
        f.origin.y += f.height - h
        f.size = NSSize(width: width, height: h)
        panel.setFrame(f, display: true, animate: false)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)): move(1); return true
        case #selector(NSResponder.moveUp(_:)): move(-1); return true
        case #selector(NSResponder.cancelOperation(_:)):
            if !field.stringValue.isEmpty { field.stringValue = ""; runQuery() } else { hide() }
            return true
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

    func tableViewSelectionDidChange(_ notification: Notification) {
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().reloadData() }
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

    // MARK: - Quick Look

    private func togglePreview() {
        guard table.selectedRow >= 0, let ql = QLPreviewPanel.shared() else { return }
        if ql.isVisible { ql.orderOut(nil) } else { ql.makeKeyAndOrderFront(nil) }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { table.selectedRow >= 0 ? 1 : 0 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        URL(fileURLWithPath: results[table.selectedRow].path) as NSURL
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        // Arrow keys in the preview move through results, like Finder.
        guard event.type == .keyDown else { return false }
        if event.keyCode == 125 { move(1); return true }
        if event.keyCode == 126 { move(-1); return true }
        return false
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        results[row].snippet == nil ? 46 : 64
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: ResultCell.id, owner: nil) as? ResultCell) ?? ResultCell()
        let r = results[row]
        let name = (r.path as NSString).lastPathComponent
        cell.configure(
            name: highlightName(name),
            path: abbrev((r.path as NSString).deletingLastPathComponent),
            snippet: r.snippet.map(highlightSnippet),
            badges: badges(r),
            date: Self.relativeDate(r.path),
            shortcut: row < 9 ? "⌘\(row + 1)" : nil,
            icon: icon(r.path))
        return cell
    }

    /// How the file matched, so a surprising result explains itself.
    private func badges(_ r: SearchResult) -> [ResultCell.Badge] {
        if showingRecents { return [.init(text: "recent", color: .systemGray)] }
        if r.tier == .exact { return [.init(text: "exact name", color: .systemGreen)] }
        var out: [ResultCell.Badge] = []
        if r.sources.contains(.content) {
            out.append(Extractor.kind(for: r.path) == .image ? .init(text: "text in image", color: .systemPurple)
                                                              : .init(text: "content", color: .systemBlue))
        }
        if r.sources.contains(.meaning) { out.append(.init(text: "meaning", color: .systemOrange)) }
        return out
    }

    /// Bold the parts of the file name that match what you typed.
    private func highlightName(_ name: String) -> NSAttributedString {
        let s = NSMutableAttributedString(string: name, attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .regular),
                                                                    .foregroundColor: NSColor.labelColor])
        guard !showingRecents else { return s }
        let words = field.stringValue.split(whereSeparator: { $0 == " " || $0 == "/" }).map(String.init)
        let ns = name as NSString
        for w in words where !w.isEmpty {
            var search = NSRange(location: 0, length: ns.length)
            while true {
                let r = ns.range(of: w, options: [.caseInsensitive, .diacriticInsensitive], range: search)
                if r.location == NSNotFound { break }
                s.addAttribute(.font, value: NSFont.systemFont(ofSize: 14, weight: .bold), range: r)
                search = NSRange(location: r.upperBound, length: ns.length - r.upperBound)
            }
        }
        return s
    }

    /// \u{1}…\u{2} markers from the content store become bold runs.
    private func highlightSnippet(_ raw: String) -> NSAttributedString {
        let s = Self.cleanSnippet(raw)
        let base: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: NSColor.secondaryLabelColor]
        let hit: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11.5, weight: .semibold), .foregroundColor: NSColor.labelColor]
        let out = NSMutableAttributedString()
        var inHit = false
        // Markers strictly alternate open/close, so toggling on each one is exact.
        for part in s.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\u{1}" || $0 == "\u{2}" }) {
            out.append(NSAttributedString(string: String(part), attributes: inHit ? hit : base))
            inHit.toggle()
        }
        return out
    }

    /// PDFs with custom font encodings extract as dingbats (✂ ☎ ✝) or private-use
    /// code points. Drop symbols that aren't text, decode XML entities, collapse gaps.
    private static func cleanSnippet(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for sc in s.unicodeScalars {
            switch sc.properties.generalCategory {
            case .otherSymbol, .privateUse, .unassigned, .surrogate: continue  // the \u{1}/\u{2} markers are .control, so they survive
            default: out.append(sc)
            }
        }
        var text = String(out)
        // Office XML text arrives with its entities still encoded.
        for (e, c) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&#39;", "'"), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: e, with: c)
        }
        return text.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    private static let dateFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated; return f
    }()

    private static func relativeDate(_ path: String) -> String {
        var st = stat()
        guard stat(path, &st) == 0 else { return "" }
        let d = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
        if Date().timeIntervalSince(d) < 60 { return "just now" }
        return dateFormatter.localizedString(for: d, relativeTo: Date())
    }

    private static func isDirectory(_ path: String) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &d) && d.boolValue
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

    /// Developer aid: SEEK_SNAPSHOT=/path.png renders the panel after each search.
    private func snapshot(to path: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
            guard let view = panel.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }
}

final class ResultCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("ResultCell")
    struct Badge { let text: String; let color: NSColor }

    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let path = NSTextField(labelWithString: "")
    private let snippet = NSTextField(labelWithString: "")
    private let date = NSTextField(labelWithString: "")
    private let shortcut = NSTextField(labelWithString: "")
    private let badgeStack = NSStackView()
    private var nameText = NSAttributedString(), snippetText: NSAttributedString?

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        name.lineBreakMode = .byTruncatingMiddle
        name.maximumNumberOfLines = 1
        name.cell?.usesSingleLineMode = true
        path.font = .systemFont(ofSize: 11)
        path.lineBreakMode = .byTruncatingMiddle
        snippet.lineBreakMode = .byTruncatingTail
        snippet.maximumNumberOfLines = 1
        for l in [date, shortcut] {
            l.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            l.alignment = .right
            l.setContentCompressionResistancePriority(.required, for: .horizontal)
            l.setContentHuggingPriority(.required, for: .horizontal)
        }
        badgeStack.orientation = .horizontal
        badgeStack.spacing = 4
        badgeStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        badgeStack.setContentHuggingPriority(.required, for: .horizontal)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for v in [icon, name, path, snippet, date, shortcut, badgeStack] {
            v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            icon.widthAnchor.constraint(equalToConstant: 32),
            icon.heightAnchor.constraint(equalToConstant: 32),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            name.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            badgeStack.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 8),
            badgeStack.centerYAnchor.constraint(equalTo: name.centerYAnchor),
            date.leadingAnchor.constraint(equalTo: badgeStack.trailingAnchor, constant: 8),
            date.centerYAnchor.constraint(equalTo: name.centerYAnchor),
            shortcut.leadingAnchor.constraint(equalTo: date.trailingAnchor, constant: 10),
            shortcut.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            shortcut.centerYAnchor.constraint(equalTo: name.centerYAnchor),
            shortcut.widthAnchor.constraint(equalToConstant: 26),
            path.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            path.trailingAnchor.constraint(equalTo: shortcut.trailingAnchor),
            path.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 1),
            snippet.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            snippet.trailingAnchor.constraint(equalTo: shortcut.trailingAnchor),
            snippet.topAnchor.constraint(equalTo: path.bottomAnchor, constant: 3),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(name n: NSAttributedString, path p: String, snippet s: NSAttributedString?,
                   badges: [Badge], date d: String, shortcut k: String?, icon img: NSImage) {
        nameText = n; snippetText = s
        path.stringValue = p
        snippet.isHidden = s == nil
        date.stringValue = d
        shortcut.stringValue = k ?? ""
        icon.image = img
        badgeStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for b in badges { badgeStack.addArrangedSubview(Self.pill(b)) }
        applyColors()
    }

    /// On the selected (accent-filled) row, every label turns white for contrast.
    override var backgroundStyle: NSView.BackgroundStyle { didSet { applyColors() } }

    private func applyColors() {
        let selected = backgroundStyle == .emphasized
        if selected {
            let n = NSMutableAttributedString(attributedString: nameText)
            n.addAttribute(.foregroundColor, value: NSColor.white, range: NSRange(location: 0, length: n.length))
            name.attributedStringValue = n
            if let s = snippetText {
                let m = NSMutableAttributedString(attributedString: s)
                m.addAttribute(.foregroundColor, value: NSColor.white.withAlphaComponent(0.85), range: NSRange(location: 0, length: m.length))
                snippet.attributedStringValue = m
            }
        } else {
            name.attributedStringValue = nameText
            if let s = snippetText { snippet.attributedStringValue = s }
        }
        path.textColor = selected ? NSColor.white.withAlphaComponent(0.75) : .secondaryLabelColor
        date.textColor = selected ? NSColor.white.withAlphaComponent(0.75) : .tertiaryLabelColor
        shortcut.textColor = selected ? NSColor.white.withAlphaComponent(0.75) : .tertiaryLabelColor
    }

    private static func pill(_ b: Badge) -> NSView {
        let l = NSTextField(labelWithString: b.text)
        l.font = .systemFont(ofSize: 10, weight: .semibold)
        l.textColor = b.color
        l.translatesAutoresizingMaskIntoConstraints = false
        let v = NSView()
        v.wantsLayer = true
        v.layer?.cornerRadius = 4
        v.layer?.backgroundColor = b.color.withAlphaComponent(0.16).cgColor
        v.addSubview(l)
        NSLayoutConstraint.activate([
            l.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 6),
            l.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -6),
            l.topAnchor.constraint(equalTo: v.topAnchor, constant: 1.5),
            l.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -1.5),
        ])
        return v
    }
}
