import AppKit

// MARK: - Settings window

final class SettingsWindow: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    private(set) var window: NSWindow?
    var onChange: () -> Void = {}
    var onEnableNotifications: () -> Void = {}
    var onTestAlerts: () -> Void = {}
    var onShow: () -> Void = {}

    private let modes = [("min", "Lowest remaining"), ("5h", "5-hour window"), ("week", "Weekly window")]
    private let modePopup = NSPopUpButton()
    private let codexBox = NSButton(checkboxWithTitle: "Codex", target: nil, action: nil)
    private let claudeBox = NSButton(checkboxWithTitle: "Claude", target: nil, action: nil)
    private let refreshField = NSTextField()
    let warnField = NSTextField()   // internal for tests
    private let criticalField = NSTextField()
    private let lowAlertBox = NSButton(checkboxWithTitle: "At or below 20% remaining · once per window", target: nil, action: nil)
    private let recoveryBox = NSButton(checkboxWithTitle: "When the provider confirms quota recovery", target: nil, action: nil)
    private let notificationStatus = NSTextField(wrappingLabelWithString: "Enable notifications to receive alerts.")
    private let cardWidth: CGFloat = 420

    func show() {
        if window == nil { build() }
        load()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(nil)   // open without a text field already selected
        onShow()
    }

    private func build() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: cardWidth + 40, height: 500),
                           styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        win.title = "AICreditsBar"
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        win.isReleasedWhenClosed = false
        win.delegate = self

        modePopup.addItems(withTitles: modes.map { $0.1 })
        for control in [modePopup, codexBox, claudeBox, lowAlertBox, recoveryBox] as [NSControl] {
            control.target = self
            control.action = #selector(changed)
        }
        for field in [refreshField, warnField, criticalField] {
            field.delegate = self
            field.target = self
            field.action = #selector(changed)
            field.alignment = .right
            field.widthAnchor.constraint(equalToConstant: 48).isActive = true
        }

        let providers = row([codexBox, claudeBox], spacing: 16)
        let refresh = row([refreshField, label("minutes", secondary: true)])
        let warnings = row([row([label("Orange below"), warnField, label("%")]), row([label("Red below"), criticalField, label("%")])], spacing: 28)

        let menuBarCard = card("menubar.rectangle", "Menu bar", [
            form([("Show", modePopup), ("Providers", providers), ("Check every", refresh)]),
            note("Also checks when the menu opens (at most every 2 minutes) and after the Mac wakes. The usage services rate-limit frequent checks.")])
        let warningCard = card("exclamationmark.triangle.fill", "Warnings", [warnings])
        let enable = NSButton(title: "Enable Notifications", target: self, action: #selector(enableNotifications))
        let test = NSButton(title: "Test Alerts", target: self, action: #selector(testAlerts))
        notificationStatus.font = .systemFont(ofSize: 11)
        notificationStatus.textColor = .secondaryLabelColor
        notificationStatus.preferredMaxLayoutWidth = cardWidth - 32
        let alertsCard = card("bell", "Notifications", [lowAlertBox, recoveryBox, row([enable, test]), notificationStatus])
        let sourcesCard = card("checkmark.shield.fill", "Data", [
            note("Codex — the official usage API, using your Codex CLI login (~/.codex/auth.json)."),
            note("Claude — the official usage API, using your Claude Code login (macOS Keychain)."),
            note("These are the numbers /status and /usage show. Nothing is estimated, and nothing is sent anywhere else.")])

        let reset = NSButton(title: "Reset to Defaults", target: self, action: #selector(resetDefaults))
        let done = NSButton(title: "Done", target: self, action: #selector(closeWindow))
        done.keyEquivalent = "\r"
        let footer = row([reset, NSView(), done])
        footer.distribution = .fill
        footer.widthAnchor.constraint(equalToConstant: cardWidth).isActive = true

        let column = NSStackView(views: [menuBarCard, warningCard, alertsCard, sourcesCard, footer])
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 14
        column.edgeInsets = NSEdgeInsets(top: 40, left: 20, bottom: 20, right: 20)
        column.translatesAutoresizingMaskIntoConstraints = false

        let background = NSVisualEffectView()
        background.material = .underWindowBackground
        background.blendingMode = .behindWindow
        background.state = .active
        background.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            column.topAnchor.constraint(equalTo: background.topAnchor)])
        win.contentView = background
        background.layoutSubtreeIfNeeded()
        win.setContentSize(NSSize(width: cardWidth + 40, height: column.fittingSize.height))
        window = win
    }

    private func load() {
        modePopup.selectItem(at: modes.firstIndex { $0.0 == Cfg.displayMode } ?? 0)
        codexBox.state = Cfg.isShown(.codex) ? .on : .off
        claudeBox.state = Cfg.isShown(.claude) ? .on : .off
        refreshField.stringValue = String(Int(Cfg.refreshInterval / 60))
        warnField.stringValue = String(Cfg.warnBelow)
        criticalField.stringValue = String(Cfg.criticalBelow)
        lowAlertBox.state = Cfg.lowAlerts ? .on : .off
        recoveryBox.state = Cfg.recoveryAlerts ? .on : .off
    }

    @objc private func changed() {
        Cfg.displayMode = modes[max(0, modePopup.indexOfSelectedItem)].0
        Cfg.setShown(.codex, codexBox.state == .on)
        Cfg.setShown(.claude, claudeBox.state == .on)
        Cfg.lowAlerts = lowAlertBox.state == .on
        Cfg.recoveryAlerts = recoveryBox.state == .on
        if let minutes = Double(refreshField.stringValue) { Cfg.refreshInterval = minutes * 60 }
        if let percent = Int(warnField.stringValue) { Cfg.warnBelow = min(100, max(0, percent)) }
        if let percent = Int(criticalField.stringValue) { Cfg.criticalBelow = min(100, max(0, percent)) }
        onChange()   // no load() here: it would overwrite a field the user is still editing
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        changed()
        load()   // show the value actually used (e.g. an interval clamped to 1 minute)
    }

    @objc private func resetDefaults() { Cfg.resetAll(); load(); onChange() }
    @objc private func enableNotifications() { onEnableNotifications() }
    @objc private func testAlerts() { onTestAlerts() }
    func setNotificationStatus(_ text: String) { notificationStatus.stringValue = text }
    @objc func closeWindow() {
        window?.makeFirstResponder(nil)   // commits a number typed without pressing Return
        window?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) { window?.makeFirstResponder(nil) }

    // MARK: Layout helpers

    private func label(_ string: String, secondary: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: string)
        if secondary { field.textColor = .secondaryLabelColor }
        return field
    }

    private func note(_ string: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: string)
        field.font = .systemFont(ofSize: 11)
        field.textColor = .secondaryLabelColor
        field.preferredMaxLayoutWidth = cardWidth - 32
        return field
    }

    private func row(_ views: [NSView], spacing: CGFloat = 6) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = spacing
        stack.alignment = .centerY
        return stack
    }

    private func form(_ rows: [(String, NSView)]) -> NSGridView {
        let grid = NSGridView(views: rows.map { [label($0.0), $0.1] })
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        return grid
    }

    /// A rounded card — Liquid Glass on macOS 26, a plain material before that.
    private func card(_ symbol: String, _ title: String, _ items: [NSView]) -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)) ?? NSImage())
        icon.contentTintColor = .controlAccentColor
        let heading = label(title)
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        let content = NSStackView(views: [row([icon, heading], spacing: 7)] + items)
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        content.translatesAutoresizingMaskIntoConstraints = false
        content.widthAnchor.constraint(equalToConstant: cardWidth).isActive = true

        let container: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = 18
            glass.contentView = content
            container = glass
        } else {
            let plain = NSVisualEffectView()
            plain.material = .contentBackground
            plain.blendingMode = .withinWindow
            plain.state = .active
            plain.wantsLayer = true
            plain.layer?.cornerRadius = 18
            plain.layer?.masksToBounds = true
            plain.addSubview(content)
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: plain.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: plain.trailingAnchor),
                content.topAnchor.constraint(equalTo: plain.topAnchor),
                content.bottomAnchor.constraint(equalTo: plain.bottomAnchor)])
            container = plain
        }
        container.translatesAutoresizingMaskIntoConstraints = false
        container.widthAnchor.constraint(equalToConstant: cardWidth).isActive = true
        return container
    }

    // MARK: QA

    /// Offscreen render of the settings window to a PNG (design check).
    func renderToPNG(_ path: String) throws {
        if window == nil { build() }
        load()
        guard let content = window?.contentView,
              let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { throw UsageError("Nothing to render") }
        content.layoutSubtreeIfNeeded()
        content.cacheDisplay(in: content.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw UsageError("PNG encoding failed") }
        try png.write(to: URL(fileURLWithPath: path))
    }
}
