import AppKit

// MARK: - Settings window

final class SettingsWindow: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    var window: NSWindow?
    var onChange: () -> Void = {}

    let modePopup = NSPopUpButton(); let planPopup = NSPopUpButton()
    let cCodex = NSButton(checkboxWithTitle: "Codex", target: nil, action: nil)
    let cClaude = NSButton(checkboxWithTitle: "Claude", target: nil, action: nil)
    let cGemini = NSButton(checkboxWithTitle: "Gemini", target: nil, action: nil)
    let cLabels = NSButton(checkboxWithTitle: "Show provider labels (Cx/Cl/Gm)", target: nil, action: nil)
    let fRefresh = NSTextField(); let fGreen = NSTextField(); let fYellow = NSTextField()
    let f5hBudget = NSTextField(); let fWkBudget = NSTextField()
    let fReal5h = NSTextField(); let fRealWk = NSTextField()
    let calStatus = NSTextField(labelWithString: "")
    let wHigh = NSColorWell(); let wMid = NSColorWell(); let wLow = NSColorWell(); let wUnknown = NSColorWell()
    let claudeLogin = WebLoginWindow(); let codexLogin = WebLoginWindow()
    let claudeStatus = NSTextField(labelWithString: ""); let codexStatus = NSTextField(labelWithString: "")
    var codexLoginBtn: NSButton!; var codexLogoutBtn: NSButton!

    func show() {
        if window == nil { build() }
        load()
        NSApp.activate(ignoringOtherApps: true)
        window?.center(); window?.makeKeyAndOrderFront(nil); window?.orderFrontRegardless()
        if ProcessInfo.processInfo.environment["AICB_FLOAT"] != nil {
            NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
            window?.level = .floating; window?.makeKeyAndOrderFront(nil)
        }
    }
    private func row(_ label: String, _ control: NSView) -> NSStackView {
        let l = NSTextField(labelWithString: label); l.alignment = .right
        l.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let h = NSStackView(views: [l, control]); h.orientation = .horizontal; h.spacing = 10; h.alignment = .centerY
        return h
    }
    private func num(_ f: NSTextField, _ w: CGFloat = 90) { f.delegate = self; f.target = self; f.action = #selector(changed(_:)); f.widthAnchor.constraint(equalToConstant: w).isActive = true }
    private func well(_ w: NSColorWell) { w.target = self; w.action = #selector(colorChanged(_:)); w.widthAnchor.constraint(equalToConstant: 30).isActive = true; w.heightAnchor.constraint(equalToConstant: 20).isActive = true }

    private let cardW: CGFloat = 432

    func build() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: cardW + 40, height: 624),
                           styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        win.title = "AICreditsBar"; win.titlebarAppearsTransparent = true; win.isMovableByWindowBackground = true
        win.delegate = self; win.isReleasedWhenClosed = false

        // --- controls ---
        modePopup.addItems(withTitles: ["5-hour window", "Weekly window", "Both (5h/week)", "Lowest"]); modePopup.target = self; modePopup.action = #selector(changed(_:))
        planPopup.addItems(withTitles: ["Pro", "Max 5x", "Max 20x", "Custom"]); planPopup.target = self; planPopup.action = #selector(changed(_:))
        for b in [cCodex, cClaude, cGemini, cLabels] { b.target = self; b.action = #selector(changed(_:)) }
        num(fRefresh, 56); num(fGreen, 46); num(fYellow, 46)
        for w in [wHigh, wMid, wLow, wUnknown] { well(w) }
        func sub(_ s: String) -> NSTextField { let l = NSTextField(labelWithString: s); l.font = .systemFont(ofSize: 11); l.textColor = .secondaryLabelColor; l.lineBreakMode = .byWordWrapping; l.maximumNumberOfLines = 3; l.preferredMaxLayoutWidth = cardW - 40; return l }
        func lbtn(_ t: String, _ sel: Selector) -> NSButton { let b = NSButton(title: t, target: self, action: sel); b.controlSize = .small; b.bezelStyle = .rounded; return b }
        func formGrid(_ pairs: [(String, NSView)]) -> NSGridView {
            let g = NSGridView(views: pairs.map { p -> [NSView] in
                let l = NSTextField(labelWithString: p.0); l.font = .systemFont(ofSize: 12); return [l, p.1]
            })
            g.rowSpacing = 11; g.columnSpacing = 10
            g.column(at: 0).xPlacement = .trailing; g.column(at: 1).xPlacement = .leading
            g.translatesAutoresizingMaskIntoConstraints = false
            return g
        }
        func swatch(_ name: String, _ cw: NSColorWell) -> NSStackView {
            let l = NSTextField(labelWithString: name); l.font = .systemFont(ofSize: 11); l.setContentCompressionResistancePriority(.required, for: .horizontal)
            let s = NSStackView(views: [l, cw]); s.orientation = .horizontal; s.spacing = 4; s.alignment = .centerY; return s
        }

        let providers = NSStackView(views: [cCodex, cClaude, cGemini]); providers.orientation = .horizontal; providers.spacing = 16
        let thresholds = NSStackView(views: [NSTextField(labelWithString: "green >"), fGreen, NSTextField(labelWithString: "yellow ≥"), fYellow, NSTextField(labelWithString: "%")])
        thresholds.orientation = .horizontal; thresholds.spacing = 6; thresholds.alignment = .centerY
        let colors = NSStackView(views: [swatch("High", wHigh), swatch("Mid", wMid), swatch("Low", wLow), swatch("Unk", wUnknown)])
        colors.orientation = .horizontal; colors.spacing = 12; colors.alignment = .centerY
        let claudeCtl = NSStackView(views: [claudeStatus, lbtn("Log in", #selector(loginClaude)), lbtn("Log out", #selector(logoutClaude))])
        claudeCtl.orientation = .horizontal; claudeCtl.spacing = 8; claudeCtl.alignment = .centerY
        codexLoginBtn = lbtn("Log in", #selector(loginCodex)); codexLogoutBtn = lbtn("Log out", #selector(logoutCodex))
        let codexCtl = NSStackView(views: [codexStatus, codexLoginBtn, codexLogoutBtn])
        codexCtl.orientation = .horizontal; codexCtl.spacing = 8; codexCtl.alignment = .centerY

        // --- glass card builder ---
        func icon(_ name: String) -> NSImageView {
            let iv = NSImageView()
            iv.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
            iv.contentTintColor = .controlAccentColor
            iv.setContentHuggingPriority(.required, for: .horizontal)
            return iv
        }
        func card(_ symbol: String, _ title: String, _ items: [NSView]) -> NSView {
            let t = NSTextField(labelWithString: title); t.font = .systemFont(ofSize: 13, weight: .semibold)
            let header = NSStackView(views: [icon(symbol), t]); header.orientation = .horizontal; header.spacing = 7; header.alignment = .centerY
            let inner = NSStackView(views: [header] + items); inner.orientation = .vertical; inner.alignment = .leading; inner.spacing = 9
            inner.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
            inner.translatesAutoresizingMaskIntoConstraints = false
            inner.widthAnchor.constraint(equalToConstant: cardW).isActive = true
            let container: NSView
            if #available(macOS 26.0, *), ProcessInfo.processInfo.environment["AICB_NOGLASS"] == nil {
                let g = NSGlassEffectView(); g.cornerRadius = 18; g.contentView = inner; container = g
            } else {
                let ve = NSVisualEffectView(); ve.material = .contentBackground; ve.blendingMode = .withinWindow; ve.state = .active
                ve.wantsLayer = true; ve.layer?.cornerRadius = 18; ve.layer?.masksToBounds = true
                inner.translatesAutoresizingMaskIntoConstraints = false; ve.addSubview(inner)
                NSLayoutConstraint.activate([inner.leadingAnchor.constraint(equalTo: ve.leadingAnchor), inner.trailingAnchor.constraint(equalTo: ve.trailingAnchor), inner.topAnchor.constraint(equalTo: ve.topAnchor), inner.bottomAnchor.constraint(equalTo: ve.bottomAnchor)])
                container = ve
            }
            container.translatesAutoresizingMaskIntoConstraints = false
            container.widthAnchor.constraint(equalToConstant: cardW).isActive = true
            return container
        }

        let loginCard = card("key.fill", "Accurate login", [formGrid([("Claude", claudeCtl), ("Codex", codexCtl)]),
            sub("Log in once, in-app, for the exact official % — no DevTools. Tokens expire occasionally → just log in again.")])
        let displayCard = card("slider.horizontal.3", "Menu bar", [formGrid([("Show", modePopup), ("Providers", providers), ("", cLabels), ("Refresh (s)", fRefresh)])])
        let colorsCard = card("paintpalette.fill", "Appearance", [formGrid([("Thresholds", thresholds), ("Colors", colors)])])

        let resetBtn = NSButton(title: "Reset to defaults", target: self, action: #selector(resetDefaults)); resetBtn.bezelStyle = .rounded
        let doneBtn = NSButton(title: "Done", target: self, action: #selector(closeWindow)); doneBtn.keyEquivalent = "\r"; doneBtn.bezelStyle = .rounded
        let footer = NSStackView(views: [resetBtn, NSView(), doneBtn]); footer.orientation = .horizontal; footer.distribution = .fill
        footer.widthAnchor.constraint(equalToConstant: cardW).isActive = true

        let column = NSStackView(views: [loginCard, displayCard, colorsCard, footer])
        column.orientation = .vertical; column.alignment = .centerX; column.spacing = 14
        column.edgeInsets = NSEdgeInsets(top: 40, left: 18, bottom: 18, right: 18); column.translatesAutoresizingMaskIntoConstraints = false

        let bg = NSVisualEffectView(); bg.material = .underWindowBackground; bg.blendingMode = .behindWindow; bg.state = .active
        bg.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: bg.leadingAnchor), column.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            column.topAnchor.constraint(equalTo: bg.topAnchor)])
        win.contentView = bg
        bg.layoutSubtreeIfNeeded()
        win.setContentSize(NSSize(width: cardW + 40, height: column.fittingSize.height))   // fit window to content (no stretched cards)
        window = win
    }
    func load() {
        let modes = ["5h": 0, "week": 1, "both": 2, "min": 3]
        modePopup.selectItem(at: modes[Cfg.displayMode] ?? 0)
        cCodex.state = Cfg.showCodex ? .on : .off; cClaude.state = Cfg.showClaude ? .on : .off
        cGemini.state = Cfg.showGemini ? .on : .off; cLabels.state = Cfg.showLabels ? .on : .off
        fRefresh.stringValue = String(Int(Cfg.refreshInterval)); fGreen.stringValue = String(Cfg.greenAbove); fYellow.stringValue = String(Cfg.yellowAbove)
        f5hBudget.stringValue = String(format: "%g", Cfg.claude5hBudget/1_000_000); fWkBudget.stringValue = String(format: "%g", Cfg.claudeWeekBudget/1_000_000)
        planPopup.selectItem(withTitle: Cfg.planBudgets[Cfg.claudePlan] != nil ? Cfg.claudePlan : "Custom")
        wHigh.color = Cfg.colorHigh; wMid.color = Cfg.colorMid; wLow.color = Cfg.colorLow; wUnknown.color = Cfg.colorUnknown
        f5hBudget.isEnabled = (planPopup.titleOfSelectedItem == "Custom")
        claudeStatus.stringValue = Cfg.claudeSessionKey.isEmpty ? "not logged in — using estimate" : "✓ logged in — exact official %"
        claudeStatus.textColor = Cfg.claudeSessionKey.isEmpty ? .secondaryLabelColor : .systemGreen
        // Codex needs no browser login when the codex CLI is already authed — hide the button then.
        let codexCLI = codexCLIAccessToken() != nil
        if codexCLI {
            codexStatus.stringValue = "✓ official — via your codex CLI (no login needed)"; codexStatus.textColor = .systemGreen
            codexLoginBtn?.isHidden = true; codexLogoutBtn?.isHidden = true
        } else if !Cfg.codexSessionToken.isEmpty {
            codexStatus.stringValue = "✓ logged in (ChatGPT) — exact official %"; codexStatus.textColor = .systemGreen
            codexLoginBtn?.isHidden = false; codexLogoutBtn?.isHidden = false
        } else {
            codexStatus.stringValue = "not logged in — log in to your codex CLI, or ChatGPT here"; codexStatus.textColor = .secondaryLabelColor
            codexLoginBtn?.isHidden = false; codexLogoutBtn?.isHidden = true
        }
    }
    @objc func changed(_ sender: Any?) {
        let modes = ["5h", "week", "both", "min"]
        Cfg.displayMode = modes[max(0, modePopup.indexOfSelectedItem)]
        Cfg.showCodex = cCodex.state == .on; Cfg.showClaude = cClaude.state == .on; Cfg.showGemini = cGemini.state == .on; Cfg.showLabels = cLabels.state == .on
        if let r = Double(fRefresh.stringValue) { Cfg.refreshInterval = r }
        if let g = Int(fGreen.stringValue) { Cfg.greenAbove = max(0, min(100, g)) }
        if let y = Int(fYellow.stringValue) { Cfg.yellowAbove = max(0, min(100, y)) }
        if let plan = planPopup.titleOfSelectedItem {
            Cfg.claudePlan = plan
            if let b = Cfg.planBudgets[plan] { Cfg.claude5hBudget = b }
            else if let m = Double(f5hBudget.stringValue), m > 0 { Cfg.claude5hBudget = m * 1_000_000 }
        }
        if let m = Double(fWkBudget.stringValue), m > 0 { Cfg.claudeWeekBudget = m * 1_000_000 }
        load(); onChange()
    }
    // Save ONLY the well the user actually changed, so untouched colors keep their
    // dynamic (dark/light-aware) defaults instead of being frozen to a static hex.
    @objc func colorChanged(_ sender: NSColorWell) {
        if sender === wHigh { Cfg.colorHigh = sender.color }
        else if sender === wMid { Cfg.colorMid = sender.color }
        else if sender === wLow { Cfg.colorLow = sender.color }
        else if sender === wUnknown { Cfg.colorUnknown = sender.color }
        onChange()
    }
    func controlTextDidEndEditing(_ obj: Notification) { changed(nil) }
    // Derive Claude budgets from the user's real % (read from `/usage`) and the current token sums,
    // so the displayed % matches reality at the calibration point and tracks proportionally after.
    @objc func calibrate() {
        let sums = claudeCalibrationSums()
        var done: [String] = []
        if let p = Double(fReal5h.stringValue), p > 0, p <= 100, sums.five > 0 {
            Cfg.claudePlan = "Custom"; Cfg.claude5hBudget = sums.five / (p / 100); done.append("5h≈\(tokLabel(Cfg.claude5hBudget))")
        }
        if let p = Double(fRealWk.stringValue), p > 0, p <= 100, sums.week > 0 {
            Cfg.claudeWeekBudget = sums.week / (p / 100); done.append("wk≈\(tokLabel(Cfg.claudeWeekBudget))")
        }
        calStatus.stringValue = done.isEmpty ? "Enter a non-zero % (and use Claude first so there are tokens to anchor to)."
                                             : "✓ Calibrated: \(done.joined(separator: " · ")) tokens/window"
        load(); onChange()
    }
    @objc func loginClaude() {
        claudeLogin.start(title: "Log in to Claude (claude.ai)", url: "https://claude.ai/login", domain: "claude.ai", cookieName: "sessionKey") { [weak self] val in
            Cfg.claudeSessionKey = val; Cfg.claudeOrgUuid = ""; self?.load(); self?.onChange()
        }
    }
    @objc func loginCodex() {
        codexLogin.start(title: "Log in to ChatGPT (Codex)", url: "https://chatgpt.com/auth/login", domain: "chatgpt.com", cookieName: "__Secure-next-auth.session-token") { [weak self] val in
            Cfg.codexSessionToken = val; self?.load(); self?.onChange()
        }
    }
    @objc func logoutClaude() { Cfg.claudeSessionKey = ""; Cfg.claudeOrgUuid = ""; load(); onChange() }
    @objc func logoutCodex() { Cfg.codexSessionToken = ""; load(); onChange() }
    @objc func resetDefaults() { Cfg.resetAll(); load(); onChange() }
    @objc func closeWindow() { window?.orderOut(nil) }

    // Offscreen render of the settings layout to a PNG (for design verification).
    func renderToPNG(_ path: String) {
        if window == nil { build() }
        load()
        guard let content = window?.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let r = content.bounds
        guard let rep = content.bitmapImageRepForCachingDisplay(in: r) else { return }
        content.cacheDisplay(in: r, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) { try? data.write(to: URL(fileURLWithPath: path)) }
    }
}
