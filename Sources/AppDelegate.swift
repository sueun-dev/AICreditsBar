import AppKit

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    let settings = SettingsWindow()
    let menu = NSMenu()
    let refreshQueue = DispatchQueue(label: "aicreditsbar.refresh", qos: .utility)
    var latest: [ProviderStatus] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        statusItem.button?.title = "AI …"
        menu.delegate = self
        statusItem.menu = menu
        settings.onChange = { [weak self] in self?.refresh(); self?.rescheduleTimer() }
        refresh(); rescheduleTimer()
        if CommandLine.arguments.contains("--settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.openSettings() }
        }
        if CommandLine.arguments.contains("--login-claude") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.settings.loginClaude() }
        }
        if CommandLine.arguments.contains("--login-codex") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.settings.loginCodex() }
        }
    }
    func rescheduleTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: Cfg.refreshInterval, repeats: true) { [weak self] _ in self?.refresh() }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
    @objc func manualRefresh() { refresh() }
    @objc func openSettings() { settings.show() }

    func refresh() {
        refreshQueue.async {
            let providers = [readCodex(), readClaude(), readGemini()]
            DispatchQueue.main.async { self.latest = providers; self.renderTitle(providers) }
        }
    }
    func renderTitle(_ all: [ProviderStatus]) {
        let shown = zip(all, [Cfg.showCodex, Cfg.showClaude, Cfg.showGemini]).filter { $0.1 }.map { $0.0 }
        let title = NSMutableAttributedString()
        let sep = NSAttributedString(string: "  ·  ", attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor])
        for (i, p) in shown.enumerated() { if i > 0 { title.append(sep) }; title.append(barSegment(p)) }
        if title.length == 0 { title.append(NSAttributedString(string: "AICreditsBar")) }
        statusItem.button?.attributedTitle = title
    }

    // Build the dropdown lazily so it's never swapped while open.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for p in latest {
            let planTxt = p.plan.map { " — \($0)" } ?? ""
            menu.addItem(headerItem("\(p.name)\(planTxt)\(p.throttled ? "  ⚠︎ throttled" : "")"))
            if !p.available { menu.addItem(detail("   \(p.problem ?? "unavailable")")) }
            else {
                if let f = p.fiveHour { menu.addItem(detail("   " + winLine("5h", f, age: p.snapshotAge))) }
                if let w = p.weekly { menu.addItem(detail("   " + winLine(p.name == "Claude" ? "7d" : "week", w, age: p.snapshotAge))) }
                for dd in p.details { menu.addItem(detail("   \(dd)")) }
                if let a = p.snapshotAge { menu.addItem(detail("   snapshot \(ageLabel(a))")) }
            }
            menu.addItem(.separator())
        }
        let setItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","); setItem.target = self; menu.addItem(setItem)
        let refreshItem = NSMenuItem(title: "Refresh now", action: #selector(manualRefresh), keyEquivalent: "r"); refreshItem.target = self; menu.addItem(refreshItem)
        menu.addItem(NSMenuItem(title: "Quit AICreditsBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }
    func menuWillOpen(_ menu: NSMenu) { refresh() }   // freshen for next open + title

    func winLine(_ label: String, _ w: WindowStat, age: Double?) -> String {
        if w.refilled { return "\(label): refilled ✓" + (w.note.map { " (\($0))" } ?? "") }
        if w.stale { return "\(label): \(w.remaining ?? 0)% — stale (data \(ageLabel(age)))" }
        var s = "\(label): \(w.remaining ?? 0)% left"
        if let n = w.note { s += "  (\(n))" }
        if w.resetEpoch != nil { s += "  · reset \(resetLabel(w.resetEpoch))" }
        return s
    }
    func headerItem(_ s: String) -> NSMenuItem {
        let it = NSMenuItem(title: s, action: nil, keyEquivalent: ""); it.isEnabled = false
        it.attributedTitle = NSAttributedString(string: s, attributes: [.font: NSFont.boldSystemFont(ofSize: 12), .foregroundColor: NSColor.labelColor]); return it
    }
    func detail(_ s: String) -> NSMenuItem {
        let it = NSMenuItem(title: s, action: nil, keyEquivalent: ""); it.isEnabled = false
        it.attributedTitle = NSAttributedString(string: s, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]); return it
    }
}
