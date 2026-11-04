import AppKit

/// Three thin bars, always in the same order: name, text, meaning. Height is
/// how strongly that retriever matched; a retriever that didn't match leaves a
/// 2 pt stub at the baseline (a zero, not a missing value). No background
/// tracks. Identity is carried by position here and by labels in `MeterLegend`,
/// which the evidence pane always shows for the selected row.
final class SignalMeter: NSView {
    var values: [Float] = [0, 0, 0] { didSet { needsDisplay = true } }
    var signal: SearchResult.Signal {
        get { .init(name: values[0], text: values[1], meaning: values[2]) }
        set { values = [newValue.name, newValue.text, newValue.meaning] }
    }
    var barWidth: CGFloat = 2.5, gap: CGFloat = 2, maxHeight: CGFloat = 14

    override var intrinsicContentSize: NSSize {
        NSSize(width: barWidth * CGFloat(values.count) + gap * CGFloat(max(0, values.count - 1)), height: maxHeight)
    }
    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        for (i, v) in values.enumerated() {
            let x = CGFloat(i) * (barWidth + gap)
            let on = v > 0
            let h = on ? max(4, CGFloat(v) * maxHeight) : 2
            (on ? Theme.ink : Theme.meterOff).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: 0, width: barWidth, height: h), xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
}

/// The labeled form of the meter: the legend that makes the row glyph legible.
final class MeterLegend: NSStackView {
    private let items: [(SignalMeter, NSTextField)] = ["name", "text", "meaning"].map { label in
        let m = SignalMeter()
        m.values = [0]
        m.maxHeight = 11
        let l = NSTextField(labelWithString: label)
        l.font = Theme.ui(11.5, .medium)
        return (m, l)
    }

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 14
        for (m, l) in items {
            let pair = NSStackView(views: [m, l])
            pair.spacing = 5
            pair.alignment = .lastBaseline
            m.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([m.widthAnchor.constraint(equalToConstant: 2.5), m.heightAnchor.constraint(equalToConstant: 11)])
            addArrangedSubview(pair)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ s: SearchResult.Signal, isImage: Bool) {
        let values = [s.name, s.text, s.meaning]
        for (i, (m, l)) in items.enumerated() {
            m.values = [values[i]]
            l.stringValue = i == 1 && isImage ? "text in image" : ["name", "text", "meaning"][i]
            l.textColor = values[i] > 0 ? Theme.ink : Theme.ink3
        }
    }
}

/// Row views draw nothing: the sliding `SelectionIndicator` is the selection.
final class PlainRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {}
    override func drawBackground(in dirtyRect: NSRect) {}
    override var isEmphasized: Bool { get { false } set {} }
}

/// One tinted capsule with an accent bar on its leading edge. It glides to the
/// selected row (120 ms, decelerating), so your eye follows the move instead
/// of re-finding the highlight after it jumps.
final class SelectionIndicator: NSView {
    private let bar = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Theme.Radius.row
        layer?.addSublayer(bar)
        bar.cornerRadius = 1.5
        updateColors()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        bar.frame = CGRect(x: 0, y: 10, width: 3, height: max(0, bounds.height - 20))
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() { updateColors() }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Theme.selection.cgColor
            bar.backgroundColor = Theme.accent.cgColor
        }
    }

    func move(to rect: NSRect, animated: Bool) {
        guard animated, Theme.Motion.feedback > 0, !isHidden, frame.height > 0 else { frame = rect; return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Theme.Motion.feedback
            ctx.timingFunction = Theme.Motion.land
            animator().frame = rect
        }
    }
}

final class ResultCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("ResultCell")

    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let path = NSTextField(labelWithString: "")
    private let meter = SignalMeter()
    private let shortcut = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        name.lineBreakMode = .byTruncatingMiddle
        name.maximumNumberOfLines = 1
        name.cell?.usesSingleLineMode = true
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        path.font = Theme.mono(10.5)
        path.textColor = Theme.ink3
        path.lineBreakMode = .byTruncatingHead
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        shortcut.font = Theme.mono(10.5)
        shortcut.textColor = Theme.ink3
        shortcut.alignment = .right
        meter.setContentHuggingPriority(.required, for: .horizontal)

        for v in [icon, name, path, meter, shortcut] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 28), icon.heightAnchor.constraint(equalToConstant: 28),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            name.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            name.trailingAnchor.constraint(lessThanOrEqualTo: meter.leadingAnchor, constant: -10),
            path.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            path.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 1),
            path.trailingAnchor.constraint(lessThanOrEqualTo: meter.leadingAnchor, constant: -10),
            meter.trailingAnchor.constraint(equalTo: shortcut.leadingAnchor, constant: -10),
            meter.centerYAnchor.constraint(equalTo: centerYAnchor),
            meter.widthAnchor.constraint(equalToConstant: 11.5), meter.heightAnchor.constraint(equalToConstant: 14),
            shortcut.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            shortcut.centerYAnchor.constraint(equalTo: centerYAnchor),
            shortcut.widthAnchor.constraint(equalToConstant: 22),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(name n: NSAttributedString, path p: String, signal: SearchResult.Signal, showMeter: Bool,
                   shortcut k: String?, icon img: NSImage) {
        name.attributedStringValue = n
        path.stringValue = p
        meter.signal = signal
        // No retriever matched (a `changed:` listing): an all-zero meter says nothing.
        meter.isHidden = !showMeter || (signal.name == 0 && signal.text == 0 && signal.meaning == 0)
        shortcut.stringValue = k ?? ""
        icon.image = img
    }
}
