import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    let settings = SettingsWindow()
    let menu = NSMenu()
    let refreshController = RefreshController()
    var latest: [ProviderStatus] = []
    private var receivedAt: [String: Double] = [:]
    private var displayTimer: Timer?
    private var refreshing = false
    private var cards: [String: ProviderCardView] = [:]
    private var activityItem: NSMenuItem?
    private var insightItem: NSMenuItem?
    var menuOpen = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "AI …"
        menu.delegate = self; statusItem.menu = menu
        latest = [("Cx", "Codex"), ("Cl", "Claude"), ("Gm", "Gemini")].map {
            ProviderStatus(key: $0.0, name: $0.1, available: false, problem: "Checking…")
        }
        refreshController.onUpdate = { [weak self] status in
            guard let self = self else { return }
            if let index = self.latest.firstIndex(where: { $0.key == status.key }) { self.latest[index] = status }
            self.receivedAt[status.key] = nowEpoch()
            self.updateDisplay()
        }
        refreshController.onActivity = { [weak self] active in
            self?.refreshing = active; self?.updateDisplay()
        }
        settings.onChange = { [weak self] in
            guard let self = self else { return }
            self.refreshController.refresh(force: true)
            self.refreshController.start(interval: Cfg.refreshInterval)
            self.rebuildMenu(self.menu); self.updateDisplay()
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wake), name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        refreshController.start(interval: Cfg.refreshInterval)
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.updateDisplay() }
        timer.tolerance = 0.2; RunLoop.main.add(timer, forMode: .common); displayTimer = timer
        if CommandLine.arguments.contains("--settings") { openSettings() }
        if CommandLine.arguments.contains("--login-claude") { settings.loginClaude() }
        if CommandLine.arguments.contains("--login-codex") { settings.loginCodex() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshController.stop(); displayTimer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
    @objc func wake() { refreshController.refresh(force: true) }
    @objc func manualRefresh() { refreshController.refresh(force: true) }
    @objc func openSettings() { settings.show() }

    func shownProviders(_ all: [ProviderStatus]) -> [ProviderStatus] {
        all.filter { p in
            switch p.key { case "Cx": return Cfg.showCodex; case "Cl": return Cfg.showClaude; case "Gm": return Cfg.showGemini; default: return false }
        }
    }
    private var displayed: [ProviderStatus] {
        shownProviders(latest).map { $0.aged(by: max(0, nowEpoch() - (receivedAt[$0.key] ?? nowEpoch()))) }
    }
    private var activityText: String {
        refreshing ? "Checking sources… · automatic" : "Auto every \(Int(Cfg.refreshInterval))s · API ≥30s"
    }
    private func updateDisplay() {
        guard statusItem != nil else { return }
        let providers = displayed
        renderTitle(providers)
        statusItem.button?.toolTip = (["AICreditsBar · " + activityText] + providers.map {
            "\($0.name): \(barInfo($0).0) · \($0.source.rawValue)"
        }).joined(separator: "\n")
        statusItem.button?.setAccessibilityLabel(statusItem.button?.toolTip)
        if menuOpen {
            // Preserve the tracking menu items and keyboard focus while updating.
            for p in providers { cards[p.key]?.update(p, checkedAt: receivedAt[p.key]) }
            activityItem?.title = activityText
            insightItem?.title = nextResetInsight(providers)
        }
    }
    func renderTitle(_ providers: [ProviderStatus]) {
        let title = NSMutableAttributedString()
        for (i, provider) in providers.enumerated() {
            if i > 0 { title.append(NSAttributedString(string: "   ")) }
            title.append(barSegment(provider))
        }
        if title.length == 0 { title.append(NSAttributedString(string: "AI")) }
        statusItem.button?.attributedTitle = title
    }
    func menuNeedsUpdate(_ menu: NSMenu) { rebuildMenu(menu) }
    func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems(); cards.removeAll()
        menu.addItem(headerItem("AICreditsBar"))
        let activity = detail(activityText); activityItem = activity; menu.addItem(activity)
        menu.addItem(.separator())
        for p in displayed {
            let item = NSMenuItem(title: p.name, action: nil, keyEquivalent: "")
            let card = ProviderCardView(status: p, checkedAt: receivedAt[p.key])
            item.view = card; cards[p.key] = card; menu.addItem(item)
        }
        if displayed.isEmpty { menu.addItem(detail("Enable a provider in Settings.")) }
        menu.addItem(.separator())
        let insight = detail(nextResetInsight(displayed)); insightItem = insight; menu.addItem(insight)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: nil)
        settings.target = self; menu.addItem(settings)
        let refresh = NSMenuItem(title: "Refresh now", action: #selector(manualRefresh), keyEquivalent: "r")
        refresh.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        refresh.target = self; menu.addItem(refresh)
        menu.addItem(NSMenuItem(title: "Quit AICreditsBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }
    func menuWillOpen(_ menu: NSMenu) { menuOpen = true; refreshController.refresh(); updateDisplay() }
    func menuDidClose(_ menu: NSMenu) { menuOpen = false }
    func headerItem(_ text: String) -> NSMenuItem {
        let item = detail(text)
        item.attributedTitle = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor])
        return item
    }
    func detail(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: ""); item.isEnabled = false; return item
    }
}
