import AppKit
import QuickLookThumbnailing

/// What the panel shows before you type: the files you're most likely after,
/// and enough about the index to trust it.
///
///   Jump back in      real thumbnails of what you opened from Seek
///   New on your Mac   what just landed in Downloads, Desktop, Documents
///   Your index        files / read inside / images read, and a 14-day
///                     activity chart; clicking a day runs `changed:<day>`
struct HomeData {
    var recents: [String] = []
    var recentsAreOpened = true
    var fresh: [(path: String, date: Date)] = []
    var files = 0, readInside = 0, imagesRead = 0
    var queued = 0
    var days: [(day: Date, count: Int)] = []

    static func load(_ s: Searcher) -> HomeData {
        var d = HomeData()
        d.fresh = newOnMac(home: s.index.home, limit: 6)
        d.recents = s.frecency.recent(limit: 5)
        if d.recents.isEmpty {
            d.recentsAreOpened = false
            d.recents = s.activity.all().lazy.map(\.path).filter(isDocument).prefix(5).map { $0 }
        }
        d.files = s.index.count
        if let c = s.content {
            d.readInside = c.indexedCount
            d.imagesRead = c.store.countWithText(kind: ContentKind.image.rawValue)
            d.queued = c.queuedCount
        }
        d.days = s.activity.perDay(days: 14)
        return d
    }

    /// What a person goes looking for: documents, slides, sheets, images, notes.
    /// Not source code, not dotfiles, not app support data.
    static let documentExts: Set<String> = ["pdf", "doc", "docx", "rtf", "odt", "pages", "ppt", "pptx", "key", "xls", "xlsx",
                                            "numbers", "csv", "md", "txt", "png", "jpg", "jpeg", "heic", "gif", "tiff",
                                            "mov", "mp4", "mp3", "m4a", "zip", "epub"]
    static let boilerplate = ["readme", "license", "changelog", "contributing", "code_of_conduct", "security", "notice"]
    static func isDocument(_ path: String) -> Bool {
        guard !path.contains("/."), !path.contains("/Library/") || path.contains("/Library/Mobile Documents/") else { return false }
        let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
        if boilerplate.contains(stem) || Extractor.excludedFragments.contains(where: path.contains) { return false }
        return documentExts.contains((path as NSString).pathExtension.lowercased())
    }

    /// Newest arrivals by "date added" (falls back to creation date), the
    /// moment a download finished or a screenshot was taken.
    static func newOnMac(home: String, limit: Int) -> [(path: String, date: Date)] {
        let keys: [URLResourceKey] = [.addedToDirectoryDateKey, .creationDateKey, .isHiddenKey]
        var out: [(String, Date)] = []
        for dir in ["Downloads", "Desktop", "Documents"] {
            let url = URL(fileURLWithPath: home).appendingPathComponent(dir)
            let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys,
                                                                      options: [.skipsHiddenFiles])) ?? []
            for u in items {
                let v = try? u.resourceValues(forKeys: Set(keys))
                if let d = v?.addedToDirectoryDate ?? v?.creationDate { out.append((u.path, d)) }
            }
        }
        return Array(out.sorted { $0.1 > $1.1 }.prefix(limit))
    }
}

/// One file as a card: a real Quick Look thumbnail, its name, how long ago.
final class HomeCard: NSView {
    let path: String
    private let thumb = NSImageView()
    private let thumbBox = NSView()
    private let name = NSTextField(labelWithString: "")
    private let when = NSTextField(labelWithString: "")
    var selected = false { didSet { updateColors() } }
    var onClick: (() -> Void)?

    init(path: String, date: Date?) {
        self.path = path
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.Radius.box
        thumbBox.wantsLayer = true
        thumbBox.layer?.cornerRadius = Theme.Radius.row
        thumbBox.layer?.masksToBounds = true
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.image = NSWorkspace.shared.icon(forFile: path)
        name.stringValue = (path as NSString).lastPathComponent
        name.font = Theme.ui(12)
        name.textColor = Theme.ink
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        when.font = Theme.mono(10.5)
        when.textColor = Theme.ink3
        when.stringValue = date.map(Self.ago) ?? ""
        for v in [thumbBox, name, when] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        thumb.translatesAutoresizingMaskIntoConstraints = false
        thumbBox.addSubview(thumb)
        NSLayoutConstraint.activate([
            thumbBox.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            thumbBox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            thumbBox.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            thumbBox.heightAnchor.constraint(equalToConstant: 98),
            thumb.leadingAnchor.constraint(equalTo: thumbBox.leadingAnchor, constant: 6),
            thumb.trailingAnchor.constraint(equalTo: thumbBox.trailingAnchor, constant: -6),
            thumb.topAnchor.constraint(equalTo: thumbBox.topAnchor, constant: 6),
            thumb.bottomAnchor.constraint(equalTo: thumbBox.bottomAnchor, constant: -6),
            name.topAnchor.constraint(equalTo: thumbBox.bottomAnchor, constant: 7),
            name.leadingAnchor.constraint(equalTo: thumbBox.leadingAnchor, constant: 2),
            name.trailingAnchor.constraint(equalTo: thumbBox.trailingAnchor, constant: -2),
            when.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 1),
            when.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            when.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
        ])
        updateColors()
        loadThumbnail()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() { updateColors() }
    override func mouseDown(with event: NSEvent) { onClick?() }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = selected ? Theme.selection.cgColor : NSColor.clear.cgColor
            layer?.borderColor = Theme.accent.cgColor
            layer?.borderWidth = selected ? 1.5 : 0
            thumbBox.layer?.backgroundColor = Theme.raise.cgColor
        }
    }

    private func loadThumbnail() {
        let req = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: path), size: CGSize(width: 150, height: 92),
                                               scale: 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { [weak self] rep, _ in
            guard let img = rep?.nsImage else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                // A real thumbnail fills the frame; an icon stays inset.
                self.thumb.image = img
                self.thumb.imageScaling = .scaleProportionallyUpOrDown
            }
        }
    }

    static let fmt: RelativeDateTimeFormatter = { let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated; return f }()
    static func ago(_ d: Date) -> String {
        Date().timeIntervalSince(d) < 60 ? "just now" : fmt.localizedString(for: d, relativeTo: Date())
    }
}

/// Files changed per day for two weeks. One series, so no legend: the caption
/// names it. Bars are thin with 2 pt gaps and rounded data-ends; no tracks,
/// no gridlines. Hover shows the exact count; click runs `changed:<day>`.
final class ActivityChart: NSView {
    var days: [(day: Date, count: Int)] = [] { didSet { needsDisplay = true; updateCaption() } }
    var onPick: ((Date) -> Void)?
    let caption = NSTextField(labelWithString: "")
    let axisStart = NSTextField(labelWithString: "")
    let axisEnd = NSTextField(labelWithString: "today")
    private var hover: Int? { didSet { if hover != oldValue { needsDisplay = true; updateCaption() } } }
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(tracking!)
    }

    private func index(at p: NSPoint) -> Int? {
        guard !days.isEmpty, bounds.contains(p) else { return nil }
        return min(days.count - 1, max(0, Int(p.x / (bounds.width / CGFloat(days.count)))))
    }

    override func mouseMoved(with e: NSEvent) { hover = index(at: convert(e.locationInWindow, from: nil)) }
    override func mouseExited(with e: NSEvent) { hover = nil }
    override func mouseDown(with e: NSEvent) {
        if let i = index(at: convert(e.locationInWindow, from: nil)) { onPick?(days[i].day) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !days.isEmpty else { return }
        let maxCount = max(1, days.map(\.count).max() ?? 1)
        let slot = bounds.width / CGFloat(days.count)
        for (i, d) in days.enumerated() {
            let h = d.count == 0 ? 2 : max(4, CGFloat(d.count) / CGFloat(maxCount) * bounds.height)
            let r = NSRect(x: CGFloat(i) * slot + 1, y: 0, width: slot - 2, height: h)   // 2 pt gap between bars
            let isHover = hover == i
            (isHover ? Theme.accent : (d.count == 0 ? Theme.meterOff : Theme.ink2)).setFill()
            // Rounded data-end, square at the baseline.
            let p = NSBezierPath()
            let rad = min(3, r.width / 2, h / 2)
            p.move(to: NSPoint(x: r.minX, y: r.minY))
            p.line(to: NSPoint(x: r.minX, y: r.maxY - rad))
            p.appendArc(withCenter: NSPoint(x: r.minX + rad, y: r.maxY - rad), radius: rad, startAngle: 180, endAngle: 90, clockwise: true)
            p.line(to: NSPoint(x: r.maxX - rad, y: r.maxY))
            p.appendArc(withCenter: NSPoint(x: r.maxX - rad, y: r.maxY - rad), radius: rad, startAngle: 90, endAngle: 0, clockwise: true)
            p.line(to: NSPoint(x: r.maxX, y: r.minY))
            p.close()
            p.fill()
        }
    }

    private static let dayFmt: DateFormatter = { let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("EEE MMM d"); return f }()

    private func updateCaption() {
        for l in [axisStart, axisEnd] { l.font = Theme.mono(10); l.textColor = Theme.ink3 }
        if let first = days.first {
            let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("MMM d")
            axisStart.stringValue = f.string(from: first.day)
        }
        let base: [NSAttributedString.Key: Any] = [.font: Theme.mono(10.5), .foregroundColor: Theme.ink3]
        if let h = hover, h < days.count {
            let d = days[h]
            let s = NSMutableAttributedString(string: Self.dayFmt.string(from: d.day) + "   ", attributes: base)
            s.append(NSAttributedString(string: "\(d.count.formatted()) changed", attributes: [.font: Theme.mono(10.5, .semibold),
                                                                                              .foregroundColor: Theme.ink]))
            s.append(NSAttributedString(string: "   click to list them", attributes: base))
            caption.attributedStringValue = s
        } else {
            let total = days.reduce(0) { $0 + $1.count }
            caption.attributedStringValue = NSAttributedString(
                string: "\(total.formatted()) files changed in 14 days, per day", attributes: base)
        }
    }
}

/// A plain row in "New on your Mac".
final class HomeRow: NSView {
    let path: String
    var selected = false { didSet { updateColors() } }
    var onClick: (() -> Void)?
    private let bar = NSView()

    init(path: String, date: Date) {
        self.path = path
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.Radius.row
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 1.5
        let icon = NSImageView(image: NSWorkspace.shared.icon(forFile: path))
        let name = NSTextField(labelWithString: (path as NSString).lastPathComponent)
        name.font = Theme.ui(12.5); name.textColor = Theme.ink; name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let parent = NSTextField(labelWithString: ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent)
        parent.font = Theme.mono(10.5); parent.textColor = Theme.ink3
        let when = NSTextField(labelWithString: HomeCard.ago(date))
        when.font = Theme.mono(10.5); when.textColor = Theme.ink3; when.alignment = .right
        for v in [bar, icon, name, parent, when] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        for l in [parent, when] { l.setContentCompressionResistancePriority(.required, for: .horizontal) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 32),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor), bar.widthAnchor.constraint(equalToConstant: 3),
            bar.topAnchor.constraint(equalTo: topAnchor, constant: 8), bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20), icon.heightAnchor.constraint(equalToConstant: 20),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10), name.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.trailingAnchor.constraint(lessThanOrEqualTo: parent.leadingAnchor, constant: -12),
            parent.trailingAnchor.constraint(equalTo: when.leadingAnchor, constant: -14),
            parent.centerYAnchor.constraint(equalTo: centerYAnchor),
            when.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12), when.centerYAnchor.constraint(equalTo: centerYAnchor),
            when.widthAnchor.constraint(greaterThanOrEqualToConstant: 54),
        ])
        updateColors()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() { updateColors() }
    override func mouseDown(with event: NSEvent) { onClick?() }
    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = selected ? Theme.selection.cgColor : NSColor.clear.cgColor
            bar.layer?.backgroundColor = selected ? Theme.accent.cgColor : NSColor.clear.cgColor
        }
    }
}

final class HomeView: NSView {
    var onOpen: ((String) -> Void)?
    var onPickDay: ((Date) -> Void)?
    var onSelectionChange: (() -> Void)?
    private(set) var paths: [String] = []          // cards first, then rows: one keyboard order
    private var cards: [HomeCard] = []
    private var rows: [HomeRow] = []
    private(set) var selection = 0

    private let cardsTitle = HomeView.sectionTitle("Jump back in")
    private let cardsNote = HomeView.sectionNote("")
    private let cardStack = NSStackView()
    private let newTitle = HomeView.sectionTitle("New on your Mac")
    private let newNote = HomeView.sectionNote("Downloads, Desktop, Documents")
    private let rowStack = NSStackView()
    private let idxTitle = HomeView.sectionTitle("Your index")
    private let idxNote = HomeView.sectionNote("")
    private let stats = NSStackView()
    private let chart = ActivityChart()
    private let hLine = NSBox(), vLine = NSBox()
    private let emptyCards = HomeView.sectionNote("Files you open from Seek will show up here.")

    static func sectionTitle(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s); l.font = Theme.ui(12, .semibold); l.textColor = Theme.ink2; return l
    }
    static func sectionNote(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s); l.font = Theme.ui(11.5); l.textColor = Theme.ink3; return l
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        cardStack.orientation = .horizontal
        cardStack.distribution = .fillEqually
        cardStack.spacing = 10
        rowStack.orientation = .vertical
        rowStack.alignment = .leading
        rowStack.spacing = 0
        stats.orientation = .horizontal
        stats.distribution = .fillEqually
        stats.alignment = .top
        chart.onPick = { [weak self] d in self?.onPickDay?(d) }
        for b in [hLine, vLine] { b.boxType = .custom; b.borderWidth = 0; b.fillColor = Theme.line }
        idxNote.alignment = .right
        cardsNote.alignment = .right
        newNote.alignment = .right

        for v in [cardsTitle, cardsNote, cardStack, emptyCards, hLine, newTitle, newNote, rowStack, vLine,
                  idxTitle, idxNote, stats, chart, chart.axisStart, chart.axisEnd, chart.caption] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v)
        }
        let split: CGFloat = 560
        NSLayoutConstraint.activate([
            cardsTitle.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            cardsTitle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            cardsNote.firstBaselineAnchor.constraint(equalTo: cardsTitle.firstBaselineAnchor),
            cardsNote.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
            cardStack.topAnchor.constraint(equalTo: cardsTitle.bottomAnchor, constant: 8),
            cardStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            cardStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            cardStack.heightAnchor.constraint(equalToConstant: 150),
            emptyCards.centerYAnchor.constraint(equalTo: cardStack.centerYAnchor),
            emptyCards.leadingAnchor.constraint(equalTo: cardsTitle.leadingAnchor),

            hLine.topAnchor.constraint(equalTo: cardStack.bottomAnchor, constant: 12),
            hLine.leadingAnchor.constraint(equalTo: leadingAnchor), hLine.trailingAnchor.constraint(equalTo: trailingAnchor),
            hLine.heightAnchor.constraint(equalToConstant: 1),

            newTitle.topAnchor.constraint(equalTo: hLine.bottomAnchor, constant: 14),
            newTitle.leadingAnchor.constraint(equalTo: cardsTitle.leadingAnchor),
            newNote.firstBaselineAnchor.constraint(equalTo: newTitle.firstBaselineAnchor),
            newNote.trailingAnchor.constraint(equalTo: vLine.leadingAnchor, constant: -22),
            rowStack.topAnchor.constraint(equalTo: newTitle.bottomAnchor, constant: 6),
            rowStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            rowStack.trailingAnchor.constraint(equalTo: vLine.leadingAnchor, constant: -10),

            vLine.topAnchor.constraint(equalTo: hLine.bottomAnchor),
            vLine.bottomAnchor.constraint(equalTo: bottomAnchor),
            vLine.leadingAnchor.constraint(equalTo: leadingAnchor, constant: split),
            vLine.widthAnchor.constraint(equalToConstant: 1),

            idxTitle.topAnchor.constraint(equalTo: newTitle.topAnchor),
            idxTitle.leadingAnchor.constraint(equalTo: vLine.trailingAnchor, constant: 22),
            idxNote.firstBaselineAnchor.constraint(equalTo: idxTitle.firstBaselineAnchor),
            idxNote.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
            stats.topAnchor.constraint(equalTo: idxTitle.bottomAnchor, constant: 12),
            stats.leadingAnchor.constraint(equalTo: idxTitle.leadingAnchor),
            stats.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
            chart.topAnchor.constraint(equalTo: stats.bottomAnchor, constant: 22),
            chart.leadingAnchor.constraint(equalTo: idxTitle.leadingAnchor),
            chart.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
            chart.heightAnchor.constraint(equalToConstant: 64),
            chart.axisStart.topAnchor.constraint(equalTo: chart.bottomAnchor, constant: 5),
            chart.axisStart.leadingAnchor.constraint(equalTo: chart.leadingAnchor),
            chart.axisEnd.topAnchor.constraint(equalTo: chart.bottomAnchor, constant: 5),
            chart.axisEnd.trailingAnchor.constraint(equalTo: chart.trailingAnchor),
            chart.caption.topAnchor.constraint(equalTo: chart.axisStart.bottomAnchor, constant: 10),
            chart.caption.leadingAnchor.constraint(equalTo: chart.leadingAnchor),
            chart.caption.trailingAnchor.constraint(lessThanOrEqualTo: chart.trailingAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ d: HomeData) {
        cardStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rowStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        cardsTitle.stringValue = d.recentsAreOpened ? "Jump back in" : "Recently changed"
        cardsNote.stringValue = d.recentsAreOpened ? "opened with Seek" : ""
        emptyCards.isHidden = !d.recents.isEmpty
        let times = Dictionary(d.fresh.map { ($0.path, $0.date) }, uniquingKeysWith: { a, _ in a })
        cards = d.recents.map { p in
            let c = HomeCard(path: p, date: times[p] ?? Self.mtime(p))
            return c
        }
        // Keep five equal slots so a short list doesn't stretch cards to odd widths.
        for c in cards { cardStack.addArrangedSubview(c) }
        for _ in cards.count..<max(cards.count, 5) where !cards.isEmpty { cardStack.addArrangedSubview(NSView()) }
        rows = d.fresh.map { HomeRow(path: $0.path, date: $0.date) }
        for r in rows {
            rowStack.addArrangedSubview(r)
            r.widthAnchor.constraint(equalTo: rowStack.widthAnchor).isActive = true
        }
        paths = cards.map(\.path) + rows.map(\.path)
        for (i, c) in cards.enumerated() { c.onClick = { [weak self] in self?.select(i); self?.openSelected() } }
        for (i, r) in rows.enumerated() { r.onClick = { [weak self] in self?.select(self!.cards.count + i); self?.openSelected() } }

        stats.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (n, label) in [(d.files, "files"), (d.readInside, "read inside"), (d.imagesRead, "images read")] {
            stats.addArrangedSubview(Self.statTile(n, label))
        }
        idxNote.stringValue = d.queued > 0 ? "reading, \(d.queued.formatted()) left" : "up to date"
        idxNote.textColor = d.queued > 0 ? Theme.accentText : Theme.ink3
        chart.days = d.days
        select(min(selection, max(0, paths.count - 1)))
    }

    /// The hero numbers: large, tabular, the label under each in muted ink.
    private static func statTile(_ n: Int, _ label: String) -> NSView {
        let v = NSTextField(labelWithString: n.formatted())
        v.font = .monospacedDigitSystemFont(ofSize: 20, weight: .semibold)
        v.textColor = Theme.ink
        let l = NSTextField(labelWithString: label)
        l.font = Theme.ui(11); l.textColor = Theme.ink3
        let s = NSStackView(views: [v, l])
        s.orientation = .vertical; s.alignment = .leading; s.spacing = 1
        return s
    }

    private static func mtime(_ p: String) -> Date? {
        var st = stat(); guard stat(p, &st) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
    }

    var selectedPath: String? { paths.indices.contains(selection) ? paths[selection] : nil }

    func select(_ i: Int) {
        guard !paths.isEmpty else { return }
        selection = max(0, min(paths.count - 1, i))
        for (j, c) in cards.enumerated() { c.selected = j == selection }
        for (j, r) in rows.enumerated() { r.selected = cards.count + j == selection }
        onSelectionChange?()
    }

    /// ←→ walk the cards, ↓ drops from the cards into the list, ↑ climbs back.
    func moveHorizontal(_ d: Int) {
        guard selection < cards.count else { return }
        select(max(0, min(cards.count - 1, selection + d)))
    }

    func moveVertical(_ d: Int) {
        if selection < cards.count {
            if d > 0, !rows.isEmpty { select(cards.count) }
        } else {
            let r = selection - cards.count + d
            if r < 0 { if !cards.isEmpty { select(0) } } else { select(cards.count + min(r, rows.count - 1)) }
        }
    }

    func openSelected() { if let p = selectedPath { onOpen?(p) } }
}
