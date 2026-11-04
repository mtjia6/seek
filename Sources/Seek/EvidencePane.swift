import AppKit

/// Draws an image aspect-fit (or width-fit, top-aligned, for rendered PDF
/// crops) and the OCR hit boxes on top, so the boxes stay crisp at any scale.
final class HitImageView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    var boxes: [CGRect] = [] { didSet { needsDisplay = true } }
    var topAligned = false { didSet { needsDisplay = true } }
    /// Zoom onto the hits: the union of the boxes, padded, fills the view
    /// (up to 3x), so small screenshot text becomes readable.
    var zoomToBoxes = true
    var inset: CGFloat = 12

    override var isFlipped: Bool { false }

    private var imageRect: NSRect {
        guard let img = image, img.size.width > 0, img.size.height > 0 else { return .zero }
        let area = bounds.insetBy(dx: topAligned ? 0 : inset, dy: topAligned ? 0 : inset)
        var s = topAligned ? area.width / img.size.width
                           : min(area.width / img.size.width, area.height / img.size.height, 2)
        var w = img.size.width * s, h = img.size.height * s
        var rect = NSRect(x: area.midX - w / 2, y: topAligned ? area.maxY - h : area.midY - h / 2, width: w, height: h)
        if zoomToBoxes, !topAligned, let first = boxes.first {
            // Region of interest in normalized image space, padded to give context.
            var roi = boxes.dropFirst().reduce(first) { $0.union($1) }.insetBy(dx: -0.08, dy: -0.12)
            roi = roi.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            let fit = min(area.width / (roi.width * img.size.width), area.height / (roi.height * img.size.height))
            let zoom = min(3, max(1, fit / s))
            if zoom >= 1.4 {   // a smaller zoom only crops the edges without making text readable
                s *= zoom; w = img.size.width * s; h = img.size.height * s
                // Center the region of interest, then keep the image covering the area where possible.
                var x = area.midX - (roi.midX * w), y = area.midY - (roi.midY * h)
                x = min(max(x, area.maxX - w), area.minX); y = min(max(y, area.maxY - h), area.minY)
                if w < area.width { x = area.midX - w / 2 }
                if h < area.height { y = area.midY - h / 2 }
                rect = NSRect(x: x, y: y, width: w, height: h)
            }
        }
        return rect.integral
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let img = image else { return }
        let r = imageRect
        NSGraphicsContext.current?.imageInterpolation = .high
        if !topAligned {
            // A hairline frame so a white screenshot doesn't dissolve into a light pane.
            Theme.line.setStroke()
            let frame = NSBezierPath(rect: r.insetBy(dx: -0.5, dy: -0.5)); frame.lineWidth = 1; frame.stroke()
        }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).setClip()
        img.draw(in: r)
        for b in boxes {
            let box = NSRect(x: r.minX + b.minX * r.width, y: r.minY + b.minY * r.height,
                             width: b.width * r.width, height: b.height * r.height).insetBy(dx: -2, dy: -1.5)
            let p = NSBezierPath(roundedRect: box, xRadius: 2.5, yRadius: 2.5)
            Theme.hit.setFill(); p.fill()
            Theme.accent.setStroke(); p.lineWidth = 1.5; p.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// The right half of the panel: what the selected file is and proof of why it matched.
final class EvidencePane: NSView {
    private let title = NSTextField(wrappingLabelWithString: "")
    private let meta = NSTextField(labelWithString: "")
    private let legend = MeterLegend()
    private let box = NSView()
    private let imageView = HitImageView()
    private let text = NSTextField(wrappingLabelWithString: "")
    private let folderStack = NSStackView()
    private let message = NSTextField(labelWithString: "")
    private let position = NSTextField(labelWithString: "")
    private let positionPill = NSView()
    private var shownPath: String?

    /// Size the loader should render for (the content box).
    var contentSize: CGSize { box.bounds.size == .zero ? CGSize(width: 440, height: 300) : box.bounds.size }

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = Theme.ui(15, .semibold)
        title.textColor = Theme.ink
        title.maximumNumberOfLines = 2
        title.lineBreakMode = .byTruncatingMiddle
        title.cell?.truncatesLastVisibleLine = true
        meta.font = Theme.ui(11.5)
        meta.textColor = Theme.ink3
        meta.lineBreakMode = .byTruncatingTail

        box.wantsLayer = true
        box.layer?.cornerRadius = Theme.Radius.box
        box.layer?.masksToBounds = true

        text.maximumNumberOfLines = 0
        text.isSelectable = false
        folderStack.orientation = .vertical
        folderStack.alignment = .leading
        folderStack.spacing = 6
        message.font = Theme.ui(12.5)
        message.textColor = Theme.ink3
        message.alignment = .center
        position.font = Theme.mono(10.5)
        position.textColor = Theme.ink3
        position.alignment = .right

        for v in [title, meta, legend, box] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        positionPill.wantsLayer = true
        positionPill.layer?.cornerRadius = Theme.Radius.row
        for v in [imageView, text, folderStack, message, positionPill] {
            v.translatesAutoresizingMaskIntoConstraints = false; box.addSubview(v)
        }
        position.translatesAutoresizingMaskIntoConstraints = false
        positionPill.addSubview(position)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            meta.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3),
            meta.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            meta.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            legend.topAnchor.constraint(equalTo: meta.bottomAnchor, constant: 12),
            legend.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            box.topAnchor.constraint(equalTo: legend.bottomAnchor, constant: 12),
            box.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            box.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            box.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),

            imageView.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: box.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            text.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 14),
            text.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -14),
            text.topAnchor.constraint(equalTo: box.topAnchor, constant: 12),
            text.bottomAnchor.constraint(lessThanOrEqualTo: positionPill.topAnchor, constant: -6),
            folderStack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 14),
            folderStack.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor, constant: -14),
            folderStack.widthAnchor.constraint(lessThanOrEqualTo: box.widthAnchor, constant: -28),
            folderStack.topAnchor.constraint(equalTo: box.topAnchor, constant: 14),
            message.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            message.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            message.widthAnchor.constraint(lessThanOrEqualTo: box.widthAnchor, constant: -40),
            // The hit counter floats on its own pill so it stays legible over a rendered page.
            positionPill.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -8),
            positionPill.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -8),
            position.leadingAnchor.constraint(equalTo: positionPill.leadingAnchor, constant: 9),
            position.trailingAnchor.constraint(equalTo: positionPill.trailingAnchor, constant: -9),
            position.topAnchor.constraint(equalTo: positionPill.topAnchor, constant: 4),
            position.bottomAnchor.constraint(equalTo: positionPill.bottomAnchor, constant: -4),
        ])
        updateColors()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() { updateColors() }
    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            box.layer?.backgroundColor = Theme.raise.cgColor
            box.layer?.borderColor = Theme.line.cgColor
            box.layer?.borderWidth = 1
            positionPill.layer?.backgroundColor = Theme.surface.cgColor
            positionPill.layer?.borderColor = Theme.line.cgColor
            positionPill.layer?.borderWidth = 1
        }
    }

    /// Header first (instant), body when the loader delivers it.
    func showHeader(_ r: SearchResult, recent: Bool) {
        let name = (r.path as NSString).lastPathComponent
        if shownPath != r.path {
            title.stringValue = name
            meta.stringValue = ""
        }
        let s = r.signal
        legend.isHidden = recent || (s.name == 0 && s.text == 0 && s.meaning == 0)
        legend.show(s, isImage: Extractor.kind(for: r.path) == .image)
    }

    func show(_ e: Evidence) {
        let changedFile = shownPath != e.path
        if changedFile, Theme.Motion.feedback > 0 {
            let t = CATransition()
            t.type = .fade
            t.duration = Theme.Motion.feedback
            t.timingFunction = Theme.Motion.land
            box.layer?.add(t, forKey: "swap")
        }
        shownPath = e.path
        meta.stringValue = e.meta
        imageView.isHidden = true; text.isHidden = true; folderStack.isHidden = true; message.isHidden = true
        imageView.boxes = []
        switch e.body {
        case .render(let img):
            imageView.topAligned = true; imageView.image = img; imageView.isHidden = false
        case .image(let img, let boxes):
            imageView.topAligned = false; imageView.image = img; imageView.boxes = boxes; imageView.isHidden = false
        case .thumbnail(let img):
            imageView.topAligned = false; imageView.image = img; imageView.isHidden = false
        case .text(let s, _):
            text.attributedStringValue = s; text.isHidden = false
        case .folder(let items, let total):
            folderStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for it in items {
                let row = folderRow(it.name, it.path)
                folderStack.addArrangedSubview(row)
                row.widthAnchor.constraint(lessThanOrEqualTo: box.widthAnchor, constant: -28).isActive = true
            }
            if total > items.count {
                let more = NSTextField(labelWithString: "\(total - items.count) more")
                more.font = Theme.ui(11.5); more.textColor = Theme.ink3
                folderStack.addArrangedSubview(more)
            }
            if total == 0 { message.stringValue = "Empty folder"; message.isHidden = false }
            folderStack.isHidden = false
        case .none(let why):
            message.stringValue = why; message.isHidden = false
        }
        position.attributedStringValue = positionText(e)
        positionPill.isHidden = position.attributedStringValue.length == 0
    }

    /// The no-results state teaches the query language instead of showing an empty box.
    func showTips() {
        clear()
        title.stringValue = "Ways to search"
        meta.stringValue = "Seek reads names, text inside files, and text inside images."
        folderStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (q, what) in [("q3report", "Names ignore case, spaces, dashes and underscores"),
                          ("dev/notes", "Text before a slash limits results to matching folders"),
                          ("changed:yesterday", "Files changed on a day: today, yesterday, mon...sun, 2026-10-30"),
                          ("how does paging work", "Describe it in words: matched by meaning, not spelling")] {
            let code = NSTextField(labelWithString: q)
            code.font = Theme.mono(12, .medium); code.textColor = Theme.accentText
            let desc = NSTextField(labelWithString: what)
            desc.font = Theme.ui(12); desc.textColor = Theme.ink2
            desc.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            desc.lineBreakMode = .byTruncatingTail
            let row = NSStackView(views: [code, desc])
            row.orientation = .vertical; row.alignment = .leading; row.spacing = 2
            folderStack.addArrangedSubview(row)
        }
        folderStack.spacing = 14
        folderStack.isHidden = false
    }

    func clear() {
        shownPath = nil
        folderStack.spacing = 6
        title.stringValue = ""; meta.stringValue = ""
        legend.isHidden = true
        imageView.image = nil; imageView.isHidden = true; text.isHidden = true; folderStack.isHidden = true
        message.isHidden = true
        position.stringValue = ""
        positionPill.isHidden = true
    }

    private func positionText(_ e: Evidence) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let base: [NSAttributedString.Key: Any] = [.font: Theme.mono(10.5), .foregroundColor: Theme.ink3]
        var parts: [String] = []
        if let l = e.location { parts.append(l) }
        if e.hitCount > 0 { parts.append("hit \(e.hitIndex + 1) of \(e.hitCount)") }
        guard !parts.isEmpty else { return out }
        out.append(NSAttributedString(string: parts.joined(separator: "   "), attributes: base))
        if e.hitCount > 1 {
            out.append(NSAttributedString(string: "   ", attributes: base))
            out.append(Keycaps.cap("⌥↓"))
        }
        return out
    }

    private func folderRow(_ name: String, _ path: String) -> NSView {
        let icon = NSImageView(image: NSWorkspace.shared.icon(forFile: path))
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 18), icon.heightAnchor.constraint(equalToConstant: 18)])
        let label = NSTextField(labelWithString: name)
        label.font = Theme.ui(12.5); label.textColor = Theme.ink2; label.lineBreakMode = .byTruncatingMiddle
        // Long names truncate instead of pushing the whole panel wider.
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [icon, label])
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }
}

/// Key glyphs drawn as small caps, shared by the footer and the evidence pane.
enum Keycaps {
    static func cap(_ k: String) -> NSAttributedString {
        NSAttributedString(string: "\u{2009}\(k)\u{2009}", attributes: [
            .font: Theme.mono(10.5, .semibold), .foregroundColor: Theme.ink2, .backgroundColor: Theme.keycap])
    }

    static func hints(_ pairs: [(String, String)]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let label: [NSAttributedString.Key: Any] = [.font: Theme.ui(11), .foregroundColor: Theme.ink3]
        for (i, (k, l)) in pairs.enumerated() {
            if i > 0 { out.append(NSAttributedString(string: "      ", attributes: label)) }
            out.append(cap(k))
            out.append(NSAttributedString(string: "  \(l)", attributes: label))
        }
        return out
    }
}
