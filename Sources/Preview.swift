import AppKit

/// Renders the real menu-bar rings and dropdown cards to a PNG, from the readings
/// the running app last saved (no extra API call — the usage endpoints rate-limit
/// hard); a provider with nothing saved is fetched live. For QA and the README.
/// AICB_APPEARANCE=light switches from the dark to the light look.
func renderPreview(to path: String) throws {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    let dark = ProcessInfo.processInfo.environment["AICB_APPEARANCE"] != "light"
    guard let appearance = NSAppearance(named: dark ? .darkAqua : .aqua) else { throw UsageError("No appearance") }
    NSApp.appearance = appearance

    let fetchers: [Provider: () throws -> Reading] = [.codex: fetchCodexReading, .claude: fetchClaudeReading]
    let states: [(Provider, ProviderState)] = Provider.allCases.filter(Cfg.isShown).map { provider in
        if let saved = Cfg.savedReading(provider) { return (provider, ProviderState(reading: saved)) }
        var state = ProviderState()
        state.record(Result { try fetchers[provider]!() })
        return (provider, state)
    }

    let width = ProviderCardView.width + 12, barHeight: CGFloat = 30
    let cardsHeight = states.reduce(CGFloat(0)) { $0 + ProviderCardView.height(for: $1.1) }
    let root = FlippedView(frame: NSRect(x: 0, y: 0, width: width, height: barHeight + 8 + cardsHeight + 12))
    root.appearance = appearance
    root.wantsLayer = true
    root.layer?.backgroundColor = NSColor.clear.cgColor

    // Menu bar strip with the real rings, right-aligned like a status item.
    let bar = NSView(frame: NSRect(x: 0, y: 0, width: width, height: barHeight))
    bar.wantsLayer = true
    bar.layer?.backgroundColor = (dark ? NSColor(white: 0.1, alpha: 1) : NSColor(white: 0.9, alpha: 1)).cgColor
    let rings = menuBarImage(states, appearance: appearance)
    let title = NSImageView(image: rings)
    title.frame = NSRect(x: width - rings.size.width - 14, y: (barHeight - rings.size.height) / 2,
                         width: rings.size.width, height: rings.size.height)
    bar.addSubview(title)
    root.addSubview(bar)

    // Menu panel with the real cards.
    let panel = NSView(frame: NSRect(x: 0, y: barHeight + 8, width: width, height: cardsHeight + 12))
    panel.wantsLayer = true
    panel.layer?.cornerRadius = 12
    panel.layer?.backgroundColor = (dark ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.97, alpha: 1)).cgColor
    root.addSubview(panel)
    var y: CGFloat = 6
    for (provider, state) in states {
        let card = ProviderCardView(provider: provider, state: state)
        card.frame.origin = NSPoint(x: 6, y: panel.frame.minY + y)
        root.addSubview(card)
        y += card.frame.height
    }

    let window = NSWindow(contentRect: root.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = root
    window.appearance = appearance
    root.layoutSubtreeIfNeeded()
    guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { throw UsageError("Nothing to render") }
    appearance.performAsCurrentDrawingAppearance { root.cacheDisplay(in: root.bounds, to: rep) }
    guard let png = rep.representation(using: .png, properties: [:]) else { throw UsageError("PNG encoding failed") }
    try png.write(to: URL(fileURLWithPath: path))
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
