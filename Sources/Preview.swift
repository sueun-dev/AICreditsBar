import AppKit

// Render the actual native card views with explicitly synthetic data for QA.
func renderPreview(to path: String) throws {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    let dark = ProcessInfo.processInfo.environment["AICB_APPEARANCE"] == "dark"
    let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
    NSApp.appearance = appearance
    var codex = ProviderStatus(key: "Cx", name: "Codex", available: true,
                               fiveHour: WindowStat(remaining: 68, resetEpoch: nowEpoch() + 7320),
                               weekly: WindowStat(remaining: 18, resetEpoch: nowEpoch() + 176400),
                               plan: "pro", snapshotAge: 12)
    codex.source = .official
    var claude = ProviderStatus(key: "Cl", name: "Claude", available: true,
                                fiveHour: WindowStat(remaining: 42, resetEpoch: nowEpoch() + 1080),
                                weekly: WindowStat(remaining: 76))
    claude.source = .estimate
    var gemini = ProviderStatus(key: "Gm", name: "Gemini", available: true)
    gemini.source = .statusOnly
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 356, height: 560))
    root.appearance = appearance; root.wantsLayer = true
    root.layer?.backgroundColor = (dark ? NSColor(calibratedWhite: 0.13, alpha: 1) : NSColor(calibratedWhite: 0.98, alpha: 1)).cgColor
    let title = NSTextField(labelWithString: "AICreditsBar  ·  Preview / sample data")
    title.frame = NSRect(x: 24, y: 526, width: 310, height: 20)
    title.font = .systemFont(ofSize: 12, weight: .semibold); root.addSubview(title)
    let subtitle = NSTextField(labelWithString: "Auto every 15s · online readings ≥30s")
    subtitle.frame = NSRect(x: 24, y: 505, width: 310, height: 18)
    subtitle.font = .systemFont(ofSize: 11); subtitle.textColor = .secondaryLabelColor; root.addSubview(subtitle)
    for (index, status) in [codex, claude, gemini].enumerated() {
        let card = ProviderCardView(status: status, checkedAt: nowEpoch())
        card.frame.origin = NSPoint(x: 0, y: 344 - index * 152); root.addSubview(card)
    }
    let footer = NSTextField(labelWithString: nextResetInsight([codex, claude, gemini]))
    footer.frame = NSRect(x: 24, y: 12, width: 310, height: 18); footer.font = .systemFont(ofSize: 11)
    root.addSubview(footer)
    let window = NSWindow(contentRect: root.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = root; window.appearance = appearance
    root.layoutSubtreeIfNeeded()
    guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else {
        throw NSError(domain: "AICreditsBar.Preview", code: 1)
    }
    appearance.performAsCurrentDrawingAppearance { root.cacheDisplay(in: root.bounds, to: rep) }
    guard let data = rep.representation(using: .png, properties: [:]) else { throw NSError(domain: "AICreditsBar.Preview", code: 2) }
    try data.write(to: URL(fileURLWithPath: path))
}
