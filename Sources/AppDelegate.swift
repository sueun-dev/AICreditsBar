import AppKit

/// Sent by `aicreditsbar --settings` when a copy is already running.
let showSettingsNotification = Notification.Name("com.sueun.aicreditsbar.showSettings")

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let settings = SettingsWindow()
    private let refresher = RefreshController()
    private let notifications = NotificationController()
    private var states: [Provider: ProviderState] = [:]
    private var cards: [Provider: ProviderCardView] = [:]
    private var displayTimer: Timer?
    private var menuOpen = false
    private var enabledProviders = Set<Provider>()
    private var lastGauges: [MenuBarGauge] = []
    private var lastProviders: [Provider] = []
    private var wakeWork: DispatchWorkItem?
    private var appearanceObserver: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageOnly
        menu.delegate = self
        statusItem.menu = menu
        Cfg.removeLegacyKeys()
        for provider in Provider.allCases { states[provider] = ProviderState(reading: Cfg.savedReading(provider), restored: true) }
        enabledProviders = Set(shownProviders)
        refresher.isEnabled = { Cfg.isShown($0) }
        refresher.onResult = { [weak self] provider, result in self?.record(provider, result) }
        settings.onChange = { [weak self] in self?.settingsChanged() }
        settings.onEnableNotifications = { [weak self] in self?.notifications.requestPermission() }
        settings.onTestAlerts = { [weak self] in self?.notifications.testAlerts() }
        settings.onShow = { [weak self] in self?.notifications.updatePermissionStatus() }
        notifications.onStatus = { [weak self] in self?.settings.setNotificationStatus($0) }
        notifications.onOpen = { [weak self] in self?.openSettings() }
        notifications.start()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake),
                                                          name: NSWorkspace.didWakeNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(openSettings),
                                                            name: showSettingsNotification, object: nil)
        // The menu bar flips between light and dark text with the wallpaper; repaint the rings.
        appearanceObserver = statusItem.button?.observe(\.effectiveAppearance) { [weak self] _, _ in self?.updateTitle(force: true) }
        updateTitle(force: true)
        refresher.start(every: Cfg.refreshInterval)
        scheduleDisplay()
        if CommandLine.arguments.contains("--settings") { openSettings() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refresher.stop()
        displayTimer?.invalidate(); wakeWork?.cancel()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }

    private func record(_ provider: Provider, _ result: Result<Reading, Error>) {
        guard Cfg.isShown(provider) else { return }
        states[provider, default: ProviderState()].record(result)
        if case .success(let reading) = result {
            Cfg.save(reading, for: provider)
            notifications.record(reading, provider: provider)
        }
        updateTitle()
        if let state = states[provider] { cards[provider]?.update(state) }
        scheduleDisplay()
    }

    private func settingsChanged() {
        let enabled = Set(shownProviders)
        let added = enabled.subtracting(enabledProviders)
        if refresher.interval != Cfg.refreshInterval || enabled != enabledProviders {
            refresher.start(every: Cfg.refreshInterval, refreshImmediately: false)
        }
        enabledProviders = enabled
        if !added.isEmpty { refresher.refresh(providers: added) }
        updateTitle()
        scheduleDisplay()
    }

    private var shownProviders: [Provider] { Provider.allCases.filter(Cfg.isShown) }

    private func updateTitle(force: Bool = false) {
        guard let button = statusItem?.button else { return }
        let now = nowEpoch()
        let items = shownProviders.map { ($0, states[$0] ?? ProviderState()) }
        let gauges = items.map { menuBarGauge($0.1, now: now) }
        if force || gauges != lastGauges || shownProviders != lastProviders {
            button.image = items.isEmpty
                ? NSImage(systemSymbolName: "speedometer", accessibilityDescription: "AICreditsBar")
                : menuBarImage(items, appearance: button.effectiveAppearance, now: now)
            lastGauges = gauges; lastProviders = shownProviders
        }
        // Exact numbers on hover; click for every limit.
        let summary = items.map { provider, state -> String in
            let gauge = menuBarGauge(state, now: now)
            var line = "\(provider.rawValue): \(gauge.text)"
            if gauge.left != nil, let window = state.reading.flatMap({ menuBarWindow($0, now: now) }) { line += " left · \(window.label)" }
            if let error = state.error { line += " (\(error.message))" }
            return line
        }.joined(separator: "\n")
        button.toolTip = summary
        button.setAccessibilityLabel("AICreditsBar\n" + summary)
    }

    @objc private func refreshNow() { refresher.refresh() }
    @objc private func openSettings() { settings.show() }
    @objc private func didWake() {
        // The network is often still coming back right after wake.
        wakeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresher.refresh(minimumGap: 30) }
        wakeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
        updateTitle(); scheduleDisplay()
    }

    private func scheduleDisplay() {
        displayTimer?.invalidate(); displayTimer = nil
        let visible = shownProviders.compactMap { states[$0] }
        guard let next = nextDisplayChange(visible, now: nowEpoch(), menuOpen: menuOpen) else { return }
        let timer = Timer(fire: Date(timeIntervalSince1970: next), interval: 0, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.updateTitle()
            if self.menuOpen { self.cards.values.forEach { $0.updateTime() } }
            self.scheduleDisplay()
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common); displayTimer = timer
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        cards.removeAll()
        for provider in shownProviders {
            let card = ProviderCardView(provider: provider, state: states[provider] ?? ProviderState())
            let item = NSMenuItem()
            item.view = card
            cards[provider] = card
            menu.addItem(item)
        }
        if cards.isEmpty {
            let empty = NSMenuItem(title: "Turn on Codex or Claude in Settings", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        menu.addItem(.separator())
        menu.addItem(command("Refresh Now", #selector(refreshNow), key: "r"))
        menu.addItem(command("Settings…", #selector(openSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit AICreditsBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        refresher.refresh(minimumGap: 120)
        scheduleDisplay()
    }

    func menuDidClose(_ menu: NSMenu) {
        menuOpen = false
        cards.removeAll()
        scheduleDisplay()
    }

    private func command(_ title: String, _ action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }
}
