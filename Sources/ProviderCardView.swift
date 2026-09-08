import AppKit

func nextResetInsight(_ providers: [ProviderStatus]) -> String {
    let resets = providers.filter { $0.available && $0.source != .estimate }.flatMap { p in
        [p.fiveHour, p.weekly].compactMap { window -> (String, Double)? in
            guard let w = window, !w.stale, let reset = w.resetEpoch, reset > nowEpoch() else { return nil }
            return (p.name, reset)
        }
    }
    guard let next = resets.min(by: { $0.1 < $1.1 }) else { return "Live sources · estimates clearly marked" }
    return "Next reset · \(next.0) \(resetLabel(next.1))"
}

// Native menu cards with fixed geometry, keeping an open menu steady on updates.
final class ProviderCardView: NSView {
    private var status: ProviderStatus
    private var checkedAt: Double?
    private let icon = NSImageView(frame: NSRect(x: 23, y: 16, width: 18, height: 18))
    override var isFlipped: Bool { true }

    init(status: ProviderStatus, checkedAt: Double? = nil) {
        self.status = status; self.checkedAt = checkedAt
        super.init(frame: NSRect(x: 0, y: 0, width: 356, height: 152))
        icon.contentTintColor = .labelColor; addSubview(icon)
        setAccessibilityElement(true); setAccessibilityRole(.staticText)
        update(status, checkedAt: checkedAt)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ status: ProviderStatus, checkedAt: Double?) {
        self.status = status; self.checkedAt = checkedAt
        icon.image = providerGlyph(status.key, 18)
        let summaries = [("5-hour", status.fiveHour), ("Weekly", status.weekly)].map { label, w in
            "\(label): \(windowText(w))\(w?.stale == true ? " stale" : ""), reset \(resetLabel(w?.resetEpoch))"
        }
        let info = ([status.name, status.plan ?? "", status.source.rawValue, status.problem ?? ""] + summaries + status.details).joined(separator: ". ")
        setAccessibilityLabel(info); toolTip = info; needsDisplay = true
    }
    private func text(_ value: String, x: CGFloat, y: CGFloat, width: CGFloat, size: CGFloat = 11,
                      weight: NSFont.Weight = .regular, color: NSColor = .secondaryLabelColor) {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        (value as NSString).draw(in: NSRect(x: x, y: y, width: width, height: 20), withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: paragraph
        ])
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let p = status
        NSColor.labelColor.withAlphaComponent(0.035).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 10, dy: 3), xRadius: 11, yRadius: 11).fill()
        text(p.name, x: 49, y: 16, width: 112, size: 13, weight: .semibold, color: .labelColor)
        let badge = p.throttled ? "LIMIT REACHED" : p.source.rawValue.uppercased()
        text(badge, x: 173, y: 18, width: 160, size: 9, weight: .semibold, color: p.throttled ? Cfg.colorLow : .secondaryLabelColor)
        if p.available && (p.fiveHour != nil || p.weekly != nil) {
            gauge("5-hour", p.fiveHour, y: 44)
            gauge("Weekly", p.weekly, y: 83)
        } else {
            text(p.available ? "Local login found" : (p.problem ?? "Unavailable"), x: 24, y: 51, width: 308, size: 12, weight: .medium, color: .labelColor)
            text(p.available ? "Quota is not exposed by local files." : "Automatic checks will keep retrying.", x: 24, y: 77, width: 308)
        }
        let warning = p.details.first { $0.contains("failed") || $0.contains("⚠") }
        let freshness: String
        if let warning = warning { freshness = warning }
        else if p.source == .estimate { freshness = "Estimated from local activity · not official quota" }
        else if let age = p.snapshotAge { freshness = "Source updated \(ageLabel(age))" }
        else if let checked = checkedAt { freshness = "Checked \(ageLabel(nowEpoch() - checked))" }
        else { freshness = "Waiting for first reading…" }
        text(freshness, x: 24, y: 127, width: 308, size: 10)
    }
    private func gauge(_ label: String, _ window: WindowStat?, y: CGFloat) {
        let stale = window?.stale == true
        text(label, x: 24, y: y, width: 70)
        let value = windowText(window) + (window?.remaining != nil ? " left" : "") + (stale ? " · stale" : "")
        let ink = colorFor(window).blended(withFraction: 0.3, of: .labelColor) ?? colorFor(window)
        text(value, x: 93, y: y, width: 115, size: 11, weight: .semibold, color: ink)
        let reset = window?.resetEpoch.map { $0 <= nowEpoch() ? "Awaiting update" : resetLabel($0) } ?? "No reset time"
        text(reset, x: 213, y: y, width: 119, size: 10)
        let track = NSRect(x: 24, y: y + 22, width: 308, height: 5)
        NSColor.labelColor.withAlphaComponent(0.09).setFill()
        NSBezierPath(roundedRect: track, xRadius: 2.5, yRadius: 2.5).fill()
        if let remaining = window?.remaining, remaining > 0 {
            colorFor(window).withAlphaComponent(stale ? 0.45 : 0.85).setFill()
            let fill = NSRect(x: track.minX, y: track.minY, width: track.width * CGFloat(min(100, remaining)) / 100, height: track.height)
            NSBezierPath(roundedRect: fill, xRadius: 2.5, yRadius: 2.5).fill()
        }
    }
}
