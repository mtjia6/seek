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

/// Result scopes. Counts come from the fused result list, so switching scope
/// never re-runs the search.
enum Scope: Int, CaseIterable {
    case all, names, contents, images, folders
    var title: String { ["All", "Names", "Contents", "Images", "Folders"][rawValue] }
    func admits(_ r: SearchResult) -> Bool {
        switch self {
        case .all: return true
        case .names: return r.sources.contains(.name)
        case .contents: return r.sources.contains(.content) && Extractor.kind(for: r.path) != .image
        case .images: return Extractor.kind(for: r.path) == .image
        case .folders: return r.isDir
        }
    }
}

/// Text tabs with counts. Empty scopes are hidden rather than shown as "0",
/// so every visible tab leads somewhere.
final class ScopeBar: NSView {
    var onSelect: ((Scope) -> Void)?
    private(set) var selected: Scope = .all
    private var buttons: [Scope: NSButton] = [:]
    private let stack = NSStackView()
    private let caption = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .horizontal
        stack.spacing = 2
        caption.font = Theme.ui(11.5, .medium)
        caption.textColor = Theme.ink3
        for v in [stack, caption] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            caption.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            caption.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        for s in Scope.allCases {
            let b = NSButton(title: s.title, target: self, action: #selector(clicked(_:)))
            b.tag = s.rawValue
            b.isBordered = false
            b.wantsLayer = true
            b.layer?.cornerRadius = Theme.Radius.row
            b.translatesAutoresizingMaskIntoConstraints = false
            b.heightAnchor.constraint(equalToConstant: 24).isActive = true
            buttons[s] = b
            stack.addArrangedSubview(b)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func clicked(_ b: NSButton) { if let s = Scope(rawValue: b.tag) { selected = s; onSelect?(s) } }

    func showCaption(_ text: String) { caption.stringValue = text; caption.isHidden = false; stack.isHidden = true }

    func update(counts: [Scope: Int], selected: Scope) {
        caption.isHidden = true
        stack.isHidden = false
        self.selected = selected
        for s in Scope.allCases {
            guard let b = buttons[s] else { continue }
            let n = counts[s] ?? 0
            b.isHidden = s != .all && n == 0
            let on = s == selected
            let t = NSMutableAttributedString(string: "  " + s.title, attributes: [
                .font: Theme.ui(12, on ? .semibold : .regular), .foregroundColor: on ? Theme.ink : Theme.ink2])
            t.append(NSAttributedString(string: " \(n)  ", attributes: [.font: Theme.mono(10.5), .foregroundColor: Theme.ink3]))
            b.attributedTitle = t
            b.effectiveAppearance.performAsCurrentDrawingAppearance {
                b.layer?.backgroundColor = on ? Theme.keycap.cgColor : NSColor.clear.cgColor
            }
        }
    }
}

final class SearchPanel: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate,
                         QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    let searcher: Searcher
    let panel: KeyPanel
    private let root = NSVisualEffectView()
    private let surface = NSView()
    private let field = NSTextField()
    private let glass = NSImageView()
    private let scopeBar = ScopeBar()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let indicator = SelectionIndicator()
    private let evidence = EvidencePane()
    private let home = HomeView()
    private var homeMode = true
    private let listMessage = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let hints = NSTextField(labelWithString: "")
    private var lines: [NSBox] = []

    private var allResults: [SearchResult] = []
    private var results: [SearchResult] = []
    private var scope: Scope = .all
    private var showingRecents = false
    private var hit = 0
    private var iconCache: [String: NSImage] = [:]
    private let queue = DispatchQueue(label: "seek.search", qos: .userInteractive)
    private var searching = false        // main-thread only
    private var pendingText: String?     // newest query typed while one was running
    private var lastQueryTime: Double = 0
    private var keyMonitor: Any?
    private var evidenceWork: DispatchWorkItem?
    private let loader: EvidenceLoader

    // Geometry (pt). The panel is either compact (just the field) or open; it
    // never resizes per keystroke, so the field never moves under your eyes.
    private let width: CGFloat = 880
    private let headerH: CGFloat = 60
    private let scopeH: CGFloat = 38
    private let bodyH: CGFloat = 404
    private let footerH: CGFloat = 32
    private let listW: CGFloat = 356
    private var openH: CGFloat { headerH + scopeH + bodyH + footerH }

    init(searcher: Searcher) {
        self.searcher = searcher
        loader = EvidenceLoader(store: searcher.content?.store)
        panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 880, height: 60),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        panel.previewSource = self
        build()
    }

    // MARK: - Layout

    private func build() {
        root.material = .hudWindow
        root.blendingMode = .behindWindow
        root.state = .active
        root.wantsLayer = true
        root.maskImage = Self.roundedMask(radius: Theme.Radius.panel)
        panel.contentView = root

        surface.wantsLayer = true
        glass.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        glass.symbolConfiguration = .init(pointSize: 17, weight: .medium)
        glass.contentTintColor = Theme.ink3

        let placeholder = "Find a file by name, by what's in it, or by what it's about"
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .font: Theme.ui(22, .regular), .foregroundColor: Theme.ink3])
        field.font = Theme.ui(22, .medium)
        field.textColor = Theme.ink
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.cell?.usesSingleLineMode = true
        field.cell?.lineBreakMode = .byTruncatingTail

        scopeBar.onSelect = { [weak self] s in self?.setScope(s) }
        home.onOpen = { [weak self] p in self?.perform(self?.modifierAction() ?? .open, on: p) }
        home.onPickDay = { [weak self] d in self?.searchChanged(on: d) }
        home.onSelectionChange = { [weak self] in
            if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().reloadData() }
            if let out = ProcessInfo.processInfo.environment["SEEK_SNAPSHOT"] { self?.snapshot(to: out) }
        }

        table.addTableColumn(NSTableColumn(identifier: .init("c")))
        table.headerView = nil
        table.intercellSpacing = .zero
        table.rowHeight = 44
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.addSubview(indicator, positioned: .below, relativeTo: nil)
        indicator.isHidden = true

        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 2, left: 0, bottom: 6, right: 0)

        listMessage.font = Theme.ui(12.5)
        listMessage.textColor = Theme.ink3
        listMessage.alignment = .center

        status.font = Theme.mono(10.5)
        status.textColor = Theme.ink3
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hints.attributedStringValue = Keycaps.hints([("↩", "open"), ("⌘↩", "reveal"), ("⌘Y", "quick look"), ("⇥", "scope")])
        hints.setContentCompressionResistancePriority(.required, for: .horizontal)

        lines = (0..<3).map { _ in let b = NSBox(); b.boxType = .custom; b.borderWidth = 0; b.fillColor = Theme.line; return b }
        let (hLine, vLine, fLine) = (lines[0], lines[1], lines[2])

        for v in [surface, glass, field, hLine, scopeBar, scroll, listMessage, vLine, evidence, home, fLine, status, hints] {
            v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: root.leadingAnchor), surface.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            surface.topAnchor.constraint(equalTo: root.topAnchor), surface.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            glass.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            glass.centerYAnchor.constraint(equalTo: root.topAnchor, constant: headerH / 2),
            field.leadingAnchor.constraint(equalTo: glass.trailingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            field.centerYAnchor.constraint(equalTo: glass.centerYAnchor),

            hLine.topAnchor.constraint(equalTo: root.topAnchor, constant: headerH),
            hLine.leadingAnchor.constraint(equalTo: root.leadingAnchor), hLine.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            hLine.heightAnchor.constraint(equalToConstant: 1),

            scopeBar.topAnchor.constraint(equalTo: hLine.bottomAnchor),
            scopeBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scopeBar.widthAnchor.constraint(equalToConstant: listW),
            scopeBar.heightAnchor.constraint(equalToConstant: scopeH),

            scroll.topAnchor.constraint(equalTo: scopeBar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.widthAnchor.constraint(equalToConstant: listW),
            scroll.bottomAnchor.constraint(equalTo: fLine.topAnchor),
            listMessage.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            listMessage.centerYAnchor.constraint(equalTo: scroll.centerYAnchor, constant: -20),
            listMessage.widthAnchor.constraint(equalToConstant: listW - 60),

            vLine.topAnchor.constraint(equalTo: hLine.bottomAnchor),
            vLine.bottomAnchor.constraint(equalTo: fLine.topAnchor),
            vLine.leadingAnchor.constraint(equalTo: scroll.trailingAnchor),
            vLine.widthAnchor.constraint(equalToConstant: 1),

            evidence.topAnchor.constraint(equalTo: hLine.bottomAnchor),
            evidence.leadingAnchor.constraint(equalTo: vLine.trailingAnchor),
            evidence.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            evidence.bottomAnchor.constraint(equalTo: fLine.topAnchor),

            home.topAnchor.constraint(equalTo: hLine.bottomAnchor),
            home.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            home.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            home.bottomAnchor.constraint(equalTo: fLine.topAnchor),

            fLine.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -footerH),
            fLine.leadingAnchor.constraint(equalTo: root.leadingAnchor), fLine.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            fLine.heightAnchor.constraint(equalToConstant: 1),
            status.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            status.centerYAnchor.constraint(equalTo: root.bottomAnchor, constant: -footerH / 2),
            hints.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            hints.centerYAnchor.constraint(equalTo: status.centerYAnchor),
            hints.leadingAnchor.constraint(greaterThanOrEqualTo: status.trailingAnchor, constant: 16),
        ])
        updateColors()
        setMode(home: true)
        setOpen(true, animated: false)
    }

    private func updateColors() {
        panel.effectiveAppearance.performAsCurrentDrawingAppearance {
            surface.layer?.backgroundColor = Theme.surface.cgColor
            // A 1 px inner edge so the panel reads as an object on any wallpaper.
            surface.layer?.borderColor = Theme.line.cgColor
            surface.layer?.borderWidth = 1
            surface.layer?.cornerRadius = Theme.Radius.panel
        }
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let d = radius * 2 + 1
        let img = NSImage(size: NSSize(width: d, height: d), flipped: false) { r in
            NSColor.black.setFill(); NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill(); return true
        }
        img.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        img.resizingMode = .stretch
        return img
    }

    /// Home (empty query) and results share the panel; only one group is visible.
    private func setMode(home on: Bool) {
        homeMode = on
        home.isHidden = !on
        for v in [scopeBar, scroll, evidence, lines[1]] as [NSView] { v.isHidden = on }
        if on { listMessage.isHidden = true }
        hints.attributedStringValue = on
            ? Keycaps.hints([("←→↑↓", "move"), ("↩", "open"), ("⌘↩", "reveal"), ("⌘Y", "quick look")])
            : Keycaps.hints([("↩", "open"), ("⌘↩", "reveal"), ("⌘Y", "quick look"), ("⇥", "scope"), ("⌥↓", "next hit")])
    }

    private var isOpen = false
    private func setOpen(_ open: Bool, animated: Bool) {
        for v in [status, hints, lines[0], lines[2]] as [NSView] { v.isHidden = !open }
        if !open { home.isHidden = true; for v in [scopeBar, scroll, evidence, lines[1], listMessage] as [NSView] { v.isHidden = true } }
        let h = open ? openH : headerH
        var f = panel.frame
        guard abs(f.height - h) > 0.5 else { isOpen = open; return }
        isOpen = open
        f.origin.y += f.height - h          // keep the top edge (and the field) fixed
        f.size = NSSize(width: width, height: h)
        if animated && Theme.Motion.enter > 0 && panel.isVisible {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Theme.Motion.enter
                ctx.timingFunction = Theme.Motion.land
                panel.animator().setFrame(f, display: true)
            } completionHandler: { [weak self] in self?.panel.invalidateShadow() }
        } else {
            panel.setFrame(f, display: true)
            panel.invalidateShadow()
        }
    }

    // MARK: - Show / hide

    func toggle() { panel.isVisible && panel.alphaValue > 0.5 ? hide() : show() }

    func show() {
        captureFinderContext()
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let f = screen?.visibleFrame {
            // The top edge sits at a fixed height, so the field is always in the same place.
            let top = f.minY + f.height * 0.80
            panel.setFrameOrigin(NSPoint(x: (f.midX - width / 2).rounded(), y: (top - panel.frame.height).rounded()))
        }
        updateColors()
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        (field.currentEditor() as? NSTextView)?.insertionPointColor = Theme.accent
        // Enter: fade in while settling 6 pt into place (decelerating).
        if let layer = root.layer, Theme.Motion.enter > 0 {
            let drop = CABasicAnimation(keyPath: "transform.translation.y")
            drop.fromValue = 6; drop.toValue = 0
            drop.duration = Theme.Motion.enter; drop.timingFunction = Theme.Motion.land
            layer.add(drop, forKey: "enter")
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Theme.Motion.enter; ctx.timingFunction = Theme.Motion.land
            panel.animator().alphaValue = 1
        }
        installKeyMonitor()
        runQuery()
        refreshFooter()
    }

    func hide() {
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().orderOut(nil) }
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        guard panel.isVisible else { return }
        // Exit: shorter than the entrance and accelerating away.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Theme.Motion.exit; ctx.timingFunction = Theme.Motion.leave
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self, self.panel.alphaValue < 0.01 else { return }
            self.panel.orderOut(nil)
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        // Quick Look takes key status while previewing; that isn't "leaving Seek".
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { return }
        hide()
    }

    /// ⌘1–⌘9 open a result, ⌘Y toggles Quick Look, ⌥↓/⌥↑ step through hits
    /// inside the selected file. A local monitor sees these before the field
    /// editor turns them into text-navigation commands.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, self.panel.isKeyWindow else { return e }
            let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
            if mods == .option {
                if e.keyCode == 125 { self.stepHit(1); return nil }
                if e.keyCode == 126 { self.stepHit(-1); return nil }
            }
            guard mods == .command, let ch = e.charactersIgnoringModifiers else { return e }
            if ch == "y" { self.togglePreview(); return nil }
            if self.homeMode, let n = Int(ch), (1...9).contains(n), n <= self.home.paths.count {
                self.home.select(n - 1); self.home.openSelected(); return nil
            }
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
        if homeMode {
            status.stringValue = searcher.contextFolder.map { "boosting \(abbrev($0))" } ?? "type to search names, contents, and screenshots"
            return
        }
        if idx.isScanning { parts.append("indexing names \(idx.count.formatted())") }
        else { parts.append("\(idx.count.formatted()) files") }
        if let c = searcher.content, c.queuedCount > 0 { parts.append("reading contents, \(c.queuedCount.formatted()) left") }
        if !allResults.isEmpty && !showingRecents { parts.append(String(format: "%.1f ms", lastQueryTime)) }
        if let c = searcher.contextFolder { parts.append("boosting \(abbrev(c))") }
        status.stringValue = parts.joined(separator: "    ")
    }

    // MARK: - Query

    func controlTextDidChange(_ obj: Notification) { runQuery() }

    private var queryText: String { field.stringValue.trimmingCharacters(in: .whitespaces) }

    /// Latest-wins: at most one search runs; keystrokes that arrive meanwhile
    /// collapse into a single follow-up search for the newest text.
    private func runQuery() {
        let text = queryText
        if text.isEmpty { pendingText = nil; showHome(); return }
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
                guard let r, self.queryText == text else { return }
                self.lastQueryTime = ms
                self.display(r, recents: false)
            }
        }
    }

    private func showHome() {
        setMode(home: true)
        evidenceWork?.cancel()
        refreshFooter()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let d = HomeData.load(self.searcher)
            DispatchQueue.main.async {
                guard self.queryText.isEmpty else { return }
                self.home.show(d)
                if let out = ProcessInfo.processInfo.environment["SEEK_SNAPSHOT"] { self.snapshot(to: out) }
            }
        }
    }

    /// The activity chart's click: a real query you could have typed.
    private func searchChanged(on day: Date) {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        field.stringValue = "changed:" + f.string(from: day)
        (field.currentEditor() as? NSTextView)?.moveToEndOfDocument(nil)
        runQuery()
    }

    private func display(_ r: [SearchResult], recents: Bool) {
        allResults = r
        showingRecents = recents
        setMode(home: false)
        // Keep the scope if it still has results; otherwise fall back to All.
        if !allResults.contains(where: scope.admits) { scope = .all }
        applyScope(resetSelection: true)
        refreshFooter()
        if let out = ProcessInfo.processInfo.environment["SEEK_SNAPSHOT"] { snapshot(to: out) }
    }

    private func setScope(_ s: Scope) {
        guard s != scope else { return }
        scope = s
        applyScope(resetSelection: true)
    }

    private func cycleScope(_ d: Int) {
        guard !showingRecents else { return }
        let available = Scope.allCases.filter { $0 == .all || allResults.contains(where: $0.admits) }
        guard let i = available.firstIndex(of: scope) else { return }
        setScope(available[(i + d + available.count) % available.count])
    }

    private func applyScope(resetSelection: Bool) {
        results = allResults.filter(scope.admits)
        if showingRecents {
            scopeBar.showCaption("Recently opened")
        } else {
            var counts: [Scope: Int] = [:]
            for s in Scope.allCases { counts[s] = allResults.filter(s.admits).count }
            scopeBar.update(counts: counts, selected: scope)
        }
        table.reloadData()
        listMessage.isHidden = !results.isEmpty
        listMessage.stringValue = queryText.isEmpty ? ""
            : "Nothing matches \u{201C}\(queryText)\u{201D}.\nTry fewer words, or part of a name."
        scopeBar.isHidden = results.isEmpty && !showingRecents
        if results.isEmpty {
            indicator.isHidden = true
            evidence.showTips()
        } else if resetSelection {
            table.selectRowIndexes([0], byExtendingSelection: false)
            table.scrollRowToVisible(0)
            placeIndicator(animated: false)
            hit = 0
            loadEvidence(debounce: false)
        }
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().reloadData() }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if homeMode {
            switch sel {
            case #selector(NSResponder.moveDown(_:)): home.moveVertical(1); return true
            case #selector(NSResponder.moveUp(_:)): home.moveVertical(-1); return true
            case #selector(NSResponder.moveLeft(_:)): home.moveHorizontal(-1); return true
            case #selector(NSResponder.moveRight(_:)): home.moveHorizontal(1); return true
            case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)): return true
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                if let p = home.selectedPath { perform(modifierAction(), on: p) }
                return true
            default: break
            }
        }
        switch sel {
        case #selector(NSResponder.moveDown(_:)): move(1); return true
        case #selector(NSResponder.moveUp(_:)): move(-1); return true
        case #selector(NSResponder.insertTab(_:)): cycleScope(1); return true
        case #selector(NSResponder.insertBacktab(_:)): cycleScope(-1); return true
        case #selector(NSResponder.cancelOperation(_:)):
            if !field.stringValue.isEmpty { field.stringValue = ""; runQuery() } else { hide() }
            return true
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            activate(modifierAction())
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
        placeIndicator(animated: true)
        hit = 0
        loadEvidence(debounce: true)
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().reloadData() }
    }

    private func placeIndicator(animated: Bool) {
        let row = table.selectedRow
        guard row >= 0 else { indicator.isHidden = true; return }
        let rect = table.rect(ofRow: row).insetBy(dx: 8, dy: 1)
        let wasHidden = indicator.isHidden
        indicator.isHidden = false
        indicator.move(to: rect, animated: animated && !wasHidden)
    }

    // MARK: - Evidence

    private func loadEvidence(debounce: Bool) {
        evidenceWork?.cancel()
        let row = table.selectedRow
        guard row >= 0, row < results.count else { evidence.clear(); return }
        let r = results[row]
        evidence.showHeader(r, recent: showingRecents)
        let q = showingRecents ? "" : queryText
        let h = hit
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.root.layoutSubtreeIfNeeded()   // render for the box's real size, not a guess
            self.loader.load(r, query: q, hit: h, size: self.evidence.contentSize) { [weak self] e in
                guard let self, self.table.selectedRow >= 0, self.table.selectedRow < self.results.count,
                      self.results[self.table.selectedRow].path == e.path else { return }
                self.evidence.show(e)
                if let out = ProcessInfo.processInfo.environment["SEEK_SNAPSHOT"] { self.snapshot(to: out) }
            }
        }
        evidenceWork = work
        // While arrowing quickly through the list, wait for a pause before rendering.
        DispatchQueue.main.asyncAfter(deadline: .now() + (debounce ? 0.06 : 0), execute: work)
    }

    private func stepHit(_ d: Int) {
        guard table.selectedRow >= 0 else { return }
        hit += d
        loadEvidence(debounce: false)
    }

    // MARK: - Actions

    private enum Action { case open, reveal, copy }

    @objc private func doubleClicked() { activate(.open) }

    private func modifierAction() -> Action {
        let mods = NSApp.currentEvent?.modifierFlags ?? []
        return mods.contains(.command) ? .reveal : mods.contains(.option) ? .copy : .open
    }

    private func activate(_ a: Action) {
        let row = table.selectedRow
        guard row >= 0 && row < results.count else { return }
        perform(a, on: results[row].path)
    }

    private func perform(_ a: Action, on path: String) {
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

    /// The file the keyboard is on, in whichever mode is showing.
    private var currentPath: String? {
        if homeMode { return home.selectedPath }
        let r = table.selectedRow
        return r >= 0 && r < results.count ? results[r].path : nil
    }

    private func togglePreview() {
        guard currentPath != nil, let ql = QLPreviewPanel.shared() else { return }
        if ql.isVisible { ql.orderOut(nil) } else { ql.makeKeyAndOrderFront(nil) }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { currentPath == nil ? 0 : 1 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        currentPath.map { URL(fileURLWithPath: $0) as NSURL }
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        if homeMode {
            switch event.keyCode {
            case 125: home.moveVertical(1); return true
            case 126: home.moveVertical(-1); return true
            case 123: home.moveHorizontal(-1); return true
            case 124: home.moveHorizontal(1); return true
            default: return false
            }
        }
        if event.keyCode == 125 { move(1); return true }
        if event.keyCode == 126 { move(-1); return true }
        return false
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { PlainRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: ResultCell.id, owner: nil) as? ResultCell) ?? ResultCell()
        let r = results[row]
        cell.configure(name: highlightName((r.path as NSString).lastPathComponent),
                       path: abbrev((r.path as NSString).deletingLastPathComponent),
                       signal: r.signal, showMeter: !showingRecents,
                       shortcut: row < 9 ? "⌘\(row + 1)" : nil, icon: icon(r.path))
        return cell
    }

    /// The letters you typed, in the accent, inside the file name.
    private func highlightName(_ name: String) -> NSAttributedString {
        // Attributed strings ignore the label's own truncation, so the paragraph style carries it.
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingMiddle
        let s = NSMutableAttributedString(string: name, attributes: [.font: Theme.ui(13.5), .foregroundColor: Theme.ink,
                                                                    .paragraphStyle: p])
        guard !showingRecents else { return s }
        let ns = name as NSString
        for w in EvidenceLoader.terms(field.stringValue) {
            var search = NSRange(location: 0, length: ns.length)
            while true {
                let r = ns.range(of: w, options: [.caseInsensitive, .diacriticInsensitive], range: search)
                if r.location == NSNotFound { break }
                s.addAttributes([.foregroundColor: Theme.accentText, .font: Theme.ui(13.5, .semibold)], range: r)
                search = NSRange(location: r.upperBound, length: ns.length - r.upperBound)
            }
        }
        return s
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

    /// Developer aid: SEEK_SNAPSHOT=/path.png renders the panel after each update.
    private func snapshot(to path: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [self] in
            guard let view = panel.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }
}
