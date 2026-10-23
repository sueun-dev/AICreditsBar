import AppKit

// MARK: - Levels and colors

enum Level { case normal, warning, critical }

func level(forLeft left: Int) -> Level {
    let critical = min(Cfg.criticalBelow, Cfg.warnBelow), warning = max(Cfg.criticalBelow, Cfg.warnBelow)
    if left < critical { return .critical }
    if left < warning { return .warning }
    return .normal
}

/// Bar fill in the menu: green, orange, red.
func barColor(_ level: Level) -> NSColor {
    switch level {
    case .normal: return .systemGreen
    case .warning: return .systemOrange
    case .critical: return .systemRed
    }
}

/// Number color in the menu: plain text while healthy.
func numberColor(_ level: Level) -> NSColor { level == .normal ? .labelColor : barColor(level) }

// MARK: - Menu bar

/// The window whose remaining % goes in the menu bar: the chosen kind if the
/// provider has it, otherwise its tightest current limit. Limits for a single
/// model are left out — they don't stop you using the others.
func menuBarWindow(_ reading: Reading, now: Double) -> UsageWindow? {
    let general = reading.windows.filter { !$0.modelScoped }
    let preferred: WindowKind? = Cfg.displayMode == "5h" ? .session : Cfg.displayMode == "week" ? .weekly : nil
    if let kind = preferred, let window = general.first(where: { $0.kind == kind }) { return window }
    let current = general.filter { !$0.isExpired(now: now) }
    return current.min { $0.leftPercent < $1.leftPercent } ?? general.first
}

/// What the menu bar shows for one provider.
struct MenuBarGauge: Equatable {
    var left: Int?           // nil: nothing current to show (first check, no data, window past its reset)
    var level: Level = .normal
    var isCurrent = true     // false: the last good reading, kept after a failed refresh
    var checking = false     // the first check is still running
    var text: String { left.map { "\($0)%" } ?? (checking ? "…" : "—") }
}

func menuBarGauge(_ state: ProviderState, now: Double) -> MenuBarGauge {
    guard let reading = state.reading else { return MenuBarGauge(left: nil, checking: state.error == nil) }
    guard let window = menuBarWindow(reading, now: now), !window.isExpired(now: now) else { return MenuBarGauge(left: nil) }
    return MenuBarGauge(left: window.leftPercent, level: level(forLeft: window.leftPercent), isCurrent: state.isCurrent(now: now))
}

/// The status-item image: each provider's mark inside a thin ring whose arc is
/// the remaining %, clockwise from 12 o'clock. The menu bar doesn't tint images it
/// isn't given as templates, so resolve its text color when drawing — orange or
/// red when low, faded when the number isn't current.
func menuBarImage(_ items: [(Provider, ProviderState)], now: Double = nowEpoch()) -> NSImage {
    let gauges = items.map { ($0.0, menuBarGauge($0.1, now: now)) }
    let size: CGFloat = 19, gap: CGFloat = 6
    let width = CGFloat(gauges.count) * (size + gap) - gap
    let image = NSImage(size: NSSize(width: max(size, width), height: size), flipped: false) { _ in
        // AppKit temporarily changes a status button's appearance while drawing
        // menu-bar replicas. Resolve ink here; replacing button.image in an
        // effectiveAppearance observer reenters that snapshot/layout work.
        let ink = NSColor.labelColor.usingColorSpace(.sRGB) ?? .labelColor
        for (index, (provider, gauge)) in gauges.enumerated() {
            drawRing(provider, gauge, in: NSRect(x: CGFloat(index) * (size + gap), y: 0, width: size, height: size), ink: ink)
        }
        return true
    }
    image.accessibilityDescription = gauges.map { "\($0.0.rawValue) \($0.1.text)" }.joined(separator: ", ")
    return image
}

private func drawRing(_ provider: Provider, _ gauge: MenuBarGauge, in rect: NSRect, ink: NSColor) {
    let line: CGFloat = 1.5
    let tint = gauge.isCurrent && gauge.level != .normal ? barColor(gauge.level) : ink
    let ring = rect.insetBy(dx: line / 2 + 0.25, dy: line / 2 + 0.25)
    let track = NSBezierPath(ovalIn: ring)
    track.lineWidth = line
    tint.withAlphaComponent(0.3).setStroke()
    track.stroke()
    if let left = gauge.left, left > 0 {
        let arc = NSBezierPath()
        arc.appendArc(withCenter: NSPoint(x: rect.midX, y: rect.midY), radius: ring.width / 2,
                      startAngle: 90, endAngle: 90 - 360 * CGFloat(left) / 100, clockwise: true)
        arc.lineWidth = line
        arc.lineCapStyle = .round
        tint.withAlphaComponent(gauge.isCurrent ? 1 : 0.45).setStroke()
        arc.stroke()
    }
    let mark = rect.width * 0.55
    let faded = gauge.left == nil || !gauge.isCurrent
    painted(providerGlyph(provider, size: mark), ink.withAlphaComponent(faded ? 0.5 : 1))
        .draw(in: NSRect(x: rect.midX - mark / 2, y: rect.midY - mark / 2, width: mark, height: mark))
}

// MARK: - Provider marks

/// A copy of a template image in one solid color.
func painted(_ template: NSImage, _ color: NSColor) -> NSImage {
    let image = NSImage(size: template.size, flipped: false) { rect in
        template.draw(in: rect)
        color.set()
        rect.fill(using: .sourceAtop)
        return true
    }
    image.accessibilityDescription = template.accessibilityDescription
    return image
}

/// Monochrome template mark (tinted by an image view, or painted for the menu bar).
func providerGlyph(_ provider: Provider, size: CGFloat = 15) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        NSColor.black.setFill()
        NSColor.black.setStroke()
        switch provider {
        case .claude: drawClaudeSpark(in: rect)
        case .codex: drawOpenAIBlossom(in: rect)
        }
        return true
    }
    image.isTemplate = true
    image.accessibilityDescription = provider.rawValue
    return image
}

/// Claude's spark: tapered rays of slightly uneven length around a small hub.
private func drawClaudeSpark(in rect: NSRect) {
    let center = NSPoint(x: rect.midX, y: rect.midY), size = rect.width
    let lengths: [CGFloat] = [1.0, 0.82, 0.96, 0.78, 1.0, 0.86, 0.94, 0.8, 0.98, 0.84]
    let baseHalfWidth = size * 0.09, tipRadius = size * 0.045
    for (index, length) in lengths.enumerated() {
        let angle = CGFloat(index) / CGFloat(lengths.count) * 2 * .pi + .pi / 2
        let along = NSPoint(x: cos(angle), y: sin(angle)), across = NSPoint(x: -sin(angle), y: cos(angle))
        let reach = size * 0.5 * length - tipRadius
        let tip = NSPoint(x: center.x + along.x * reach, y: center.y + along.y * reach)
        let ray = NSBezierPath()
        ray.move(to: NSPoint(x: center.x + across.x * baseHalfWidth, y: center.y + across.y * baseHalfWidth))
        ray.line(to: NSPoint(x: tip.x + across.x * tipRadius, y: tip.y + across.y * tipRadius))
        ray.appendArc(withCenter: tip, radius: tipRadius, startAngle: (angle + .pi / 2) * 180 / .pi,
                      endAngle: (angle - .pi / 2) * 180 / .pi, clockwise: true)
        ray.line(to: NSPoint(x: center.x - across.x * baseHalfWidth, y: center.y - across.y * baseHalfWidth))
        ray.close()
        ray.fill()
    }
    NSBezierPath(ovalIn: NSRect(x: center.x - size * 0.12, y: center.y - size * 0.12, width: size * 0.24, height: size * 0.24)).fill()
}

/// OpenAI's blossom: six rounded links turned 60° apart.
private func drawOpenAIBlossom(in rect: NSRect) {
    let size = rect.width
    for index in 0..<6 {
        let turn = NSAffineTransform()
        turn.translateX(by: rect.midX, yBy: rect.midY)
        turn.rotate(byDegrees: CGFloat(index) * 60)
        let link = NSBezierPath(roundedRect: NSRect(x: -size * 0.115, y: -size * 0.40, width: size * 0.23, height: size * 0.50),
                                xRadius: size * 0.115, yRadius: size * 0.115)
        link.transform(using: turn as AffineTransform)
        link.lineWidth = max(size * 0.085, 1.2)   // thicker at small sizes so the links don't blur together
        link.stroke()
    }
}
