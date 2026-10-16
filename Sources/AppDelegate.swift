import AppKit

/// Sent by `aicreditsbar --settings` when a copy is already running.
let showSettingsNotification = Notification.Name("com.sueun.aicreditsbar.showSettings")

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let settings = SettingsWindow()
    private let refresher = RefreshController()
    private var states: [Provider: ProviderState] = [:]
    private var cards: [Provider: ProviderCardView] = [:]
    private var menuTimer: Timer?   // ticks the countdowns while the menu is open
    private var appearanceObserver: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageOnly
        menu.delegate = self
        statusItem.menu = menu
        Cfg.removeLegacyKeys()
        for provider in Provider.allCases { states[provider] = ProviderState(reading: Cfg.savedReading(provider)) }
        refresher.isEnabled = { Cfg.isShown($0) }
        refresher.onResult = { [weak self] provider, result in self?.record(provider, result) }
        settings.onChange = { [weak self] in self?.settingsChanged() }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake),
                                                          name: NSWorkspace.didWakeNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(openSettings),
                                                            name: showSettingsNotification, object: nil)
        // The menu bar flips between light and dark text with the wallpaper; repaint the rings.
        appearanceObserver = statusItem.button?.observe(\.effectiveAppearance) { [weak self] _, _ in self?.updateTitle() }
        updateTitle()
        refresher.start(every: Cfg.refreshInterval)
        if CommandLine.arguments.contains("--settings") { openSettings() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refresher.stop()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }

    private func record(_ provider: Provider, _ result: Result<Reading, Error>) {
        states[provider, default: ProviderState()].record(result)
        if case .success(let reading) = result { Cfg.save(reading, for: provider) }
        updateTitle()
        if let state = states[provider] { cards[provider]?.update(state) }
    }

    private func settingsChanged() {
        if refresher.interval != Cfg.refreshInterval { refresher.start(every: Cfg.refreshInterval) }
        else { refresher.refresh() }   // picks up a provider that was just switched on
        updateTitle()
    }

    private var shownProviders: [Provider] { Provider.allCases.filter(Cfg.isShown) }

    private func updateTitle() {
        guard let button = statusItem?.button else { return }
        let now = nowEpoch()
        let items = shownProviders.map { ($0, states[$0] ?? ProviderState()) }
        button.image = items.isEmpty
            ? NSImage(systemSymbolName: "speedometer", accessibilityDescription: "AICreditsBar")
            : menuBarImage(items, appearance: button.effectiveAppearance, now: now)
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.refresher.refresh() }
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
        refresher.refresh(minimumGap: 120)
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.cards.values.forEach { $0.needsDisplay = true }
        }
        RunLoop.main.add(timer, forMode: .common)
        menuTimer = timer
    }

    func menuDidClose(_ menu: NSMenu) {
        menuTimer?.invalidate()
        menuTimer = nil
    }

    private func command(_ title: String, _ action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }
}
