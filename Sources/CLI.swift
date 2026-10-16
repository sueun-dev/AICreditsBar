import AppKit

// Headless command-line interface. Returns normally when the menu-bar app
// should start; every flag it handles exits.

private func argument(after flag: String) -> String? {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
    return args[index + 1]
}

func handleCLIFlags() {
    let args = CommandLine.arguments
    if let path = argument(after: "--render-preview") {
        run { try renderPreview(to: path); print("Rendered the menu → \(path)") }
    }
    if let path = argument(after: "--render-settings") {
        run {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.accessory)
            try SettingsWindow().renderToPNG(path)
            print("Rendered settings → \(path)")
        }
    }
    if args.contains("--dump-config") {
        print("display=\(Cfg.displayMode) refresh=\(Int(Cfg.refreshInterval))s warn<\(Cfg.warnBelow)% critical<\(Cfg.criticalBelow)%")
        print("providers: " + Provider.allCases.map { "\($0.rawValue)=\(Cfg.isShown($0) ? "on" : "off")" }.joined(separator: " "))
    }
    if args.contains("--once") || args.contains("--dump-config") {
        let now = nowEpoch()
        for (provider, fetch) in [(Provider.codex, fetchCodexReading), (.claude, fetchClaudeReading)] {
            var state = ProviderState()
            state.record(Result { try fetch() })
            print(describe(provider, state, now: now))
        }
        exit(0)
    }
}

/// Plain-text report used by --once.
func describe(_ provider: Provider, _ state: ProviderState, now: Double) -> String {
    guard let reading = state.reading else {
        return "\(provider.rawValue): \(state.error?.description ?? "no data")"
    }
    var lines = [provider.rawValue + (reading.plan.map { " · \($0)" } ?? "") + (reading.limitReached ? " · LIMIT REACHED" : "")]
    let width = reading.windows.map { $0.label.count }.max() ?? 0
    for window in reading.windows {
        let name = window.label.padding(toLength: width, withPad: " ", startingAt: 0)
        if window.isExpired(now: now) { lines.append("  \(name)     —       reset passed, awaiting a new reading"); continue }
        let reset = window.resetsAt.map { "resets " + countdown(to: $0, now: now) } ?? "no reset time"
        lines.append("  \(name)  \(String(format: "%3d", window.leftPercent))% left  \(reset)")
    }
    lines += reading.notes.map { "  " + $0 }
    return lines.joined(separator: "\n")
}

private func run(_ body: () throws -> Void) -> Never {
    do { try body(); exit(0) } catch {
        fputs("error: \(error)\n", stderr)
        exit(1)
    }
}
