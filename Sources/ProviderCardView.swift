import AppKit

/// One provider in the dropdown: plan, every usage window with a bar and its
/// reset countdown, and how current the numbers are.
final class ProviderCardView: NSView {
    static let width: CGFloat = 300
    private static let left: CGFloat = 18, right: CGFloat = width - 18
    private static let rowHeight: CGFloat = 36

    private let provider: Provider
    private var state: ProviderState
    private let icon = NSImageView(frame: NSRect(x: left, y: 12, width: 16, height: 16))
    override var isFlipped: Bool { true }

    init(provider: Provider, state: ProviderState) {
        self.provider = provider
        self.state = state
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.height(for: state)))
        icon.image = providerGlyph(provider, size: 16)
        icon.contentTintColor = .labelColor
        addSubview(icon)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        describe()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static func height(for state: ProviderState) -> CGFloat {
        guard let reading = state.reading else { return 86 }
        return 66 + CGFloat(reading.windows.count) * rowHeight
    }

    func update(_ state: ProviderState) {
        self.state = state
        let height = Self.height(for: state)
        if height != frame.height { setFrameSize(NSSize(width: Self.width, height: height)) }
        describe()
        needsDisplay = true
    }
    func updateTime() { describe(); needsDisplay = true }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let now = nowEpoch()
        NSColor.labelColor.withAlphaComponent(0.05).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 3), xRadius: 10, yRadius: 10).fill()

        let nameWidth = text(provider.rawValue, x: Self.left + 23, y: 11, width: 120, font: .systemFont(ofSize: 13, weight: .semibold))
        if let plan = state.reading?.plan { badge(plan, x: Self.left + 23 + nameWidth + 7, y: 12) }
        if state.limitReached(now: now) {
            text("Limit reached", x: Self.right - 120, y: 13, width: 120, font: .systemFont(ofSize: 11, weight: .semibold),
                 color: .systemRed, alignment: .right)
        }

        guard let reading = state.reading else {
            if let error = state.error {
                text(error.message, x: Self.left, y: 40, width: Self.right - Self.left, font: .systemFont(ofSize: 12, weight: .medium))
                if let hint = error.hint {
                    text(hint, x: Self.left, y: 58, width: Self.right - Self.left, font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
                }
            } else {
                text("Checking…", x: Self.left, y: 40, width: 200, font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
            }
            return
        }

        var y: CGFloat = 40
        for window in reading.windows {
            row(window, y: y, now: now)
            y += Self.rowHeight
        }
        footer(reading, y: y + 2, now: now)
    }

    private func row(_ window: UsageWindow, y: CGFloat, now: Double) {
        let expired = window.isExpired(now: now)
        let current = !expired && state.isCurrent(now: now)
        let tone = level(forLeft: window.leftPercent)

        let labelWidth = text(window.label, x: Self.left, y: y, width: 150, font: .systemFont(ofSize: 12))
        let reset: String
        if expired { reset = "reset · awaiting new reading" }
        else if let resetsAt = window.resetsAt { reset = "resets " + countdown(to: resetsAt, now: now) }
        else { reset = "" }
        if !reset.isEmpty {
            let x = Self.left + labelWidth
            text("  ·  " + reset, x: x, y: y + 1, width: Self.right - 66 - x, font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
        }
        text(expired ? "—" : "\(window.leftPercent)% left", x: Self.right - 66, y: y, width: 66,
             font: .monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
             color: current ? numberColor(tone) : .secondaryLabelColor, alignment: .right)

        let track = NSRect(x: Self.left, y: y + 20, width: Self.right - Self.left, height: 5)
        NSColor.labelColor.withAlphaComponent(0.1).setFill()
        NSBezierPath(roundedRect: track, xRadius: 2.5, yRadius: 2.5).fill()
        guard !expired, window.leftPercent > 0 else { return }
        (current ? barColor(tone) : NSColor.secondaryLabelColor.withAlphaComponent(0.5)).setFill()
        let fill = NSRect(x: track.minX, y: track.minY, width: max(track.height, track.width * CGFloat(window.leftPercent) / 100), height: track.height)
        NSBezierPath(roundedRect: fill, xRadius: 2.5, yRadius: 2.5).fill()
    }

    private func footer(_ reading: Reading, y: CGFloat, now: Double) {
        let font = NSFont.systemFont(ofSize: 11)
        let age = ago(now - reading.fetchedAt)
        if let error = state.error {
            text("⚠︎", x: Self.left, y: y, width: 14, font: font, color: .systemOrange)
            text("\(error.message) · numbers from \(age)", x: Self.left + 15, y: y, width: Self.right - Self.left - 15,
                 font: font, color: .secondaryLabelColor)
            return
        }
        text((state.isCurrent(now: now) ? "Updated " : "Last updated ") + age, x: Self.left, y: y, width: 140, font: font, color: .tertiaryLabelColor)
        text(reading.notes.joined(separator: " · "), x: Self.left + 140, y: y, width: Self.right - Self.left - 140,
             font: font, color: .secondaryLabelColor, alignment: .right)
    }

    private func badge(_ label: String, x: CGFloat, y: CGFloat) {
        let font = NSFont.systemFont(ofSize: 10, weight: .medium)
        let width = (label as NSString).size(withAttributes: [.font: font]).width + 12
        NSColor.labelColor.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: y, width: width, height: 16), xRadius: 8, yRadius: 8).fill()
        text(label, x: x + 6, y: y + 1.5, width: width, font: font, color: .secondaryLabelColor)
    }

    /// Draws one line of text, truncating with "…" at `width`; returns the width used.
    @discardableResult
    private func text(_ string: String, x: CGFloat, y: CGFloat, width: CGFloat, font: NSFont,
                      color: NSColor = .labelColor, alignment: NSTextAlignment = .left) -> CGFloat {
        guard width > 0 else { return 0 }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        style.alignment = alignment
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
        (string as NSString).draw(in: NSRect(x: x, y: y, width: width, height: font.pointSize + 6), withAttributes: attributes)
        return min(width, (string as NSString).size(withAttributes: attributes).width)
    }

    // MARK: Accessibility / tooltip

    private func describe() {
        var lines = [provider.rawValue + (state.reading?.plan.map { " · \($0)" } ?? "")]
        if let reading = state.reading {
            for window in reading.windows {
                if window.isExpired(now: nowEpoch()) { lines.append("\(window.label): reset passed, awaiting a new reading"); continue }
                let reset = window.resetsAt.map { " · resets \(absoluteTime($0))" } ?? ""
                lines.append("\(window.label): \(window.leftPercent)% left (\(pctClamp(window.usedPercent))% used)\(reset)")
            }
            lines += reading.notes
        }
        if let error = state.error { lines.append(error.description) }
        let summary = lines.joined(separator: "\n")
        toolTip = summary
        setAccessibilityLabel(summary)
    }
}
