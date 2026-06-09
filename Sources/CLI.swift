import AppKit

// Headless command-line interface. Returns normally for the GUI to start;
// handlers that fully service a flag call exit() themselves.

func argValue(_ flag: String) -> Double? {
    guard let i = CommandLine.arguments.firstIndex(of: flag), i + 1 < CommandLine.arguments.count else { return nil }
    return Double(CommandLine.arguments[i + 1])
}
func argString(_ flag: String) -> String? {
    guard let i = CommandLine.arguments.firstIndex(of: flag), i + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[i + 1]
}

/// Handle any CLI flag and exit; returns if there's nothing to do but launch the GUI.
func handleCLIFlags() {
    if let path = argString("--render-settings") {
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.accessory)
        SettingsWindow().renderToPNG(path)
        print("rendered settings → \(path)"); exit(0)
    }
    if let k = argString("--set-claude-key") {
        Cfg.claudeSessionKey = k; Cfg.claudeOrgUuid = ""; Cfg.d.synchronize()
        print("Claude sessionKey saved (\(k.count) chars). Restart the app to use official data."); exit(0)
    }
    if let t = argString("--set-codex-token") {
        Cfg.codexSessionToken = t; Cfg.d.synchronize()
        print("Codex session-token saved (\(t.count) chars). Restart the app to use official data."); exit(0)
    }
    if CommandLine.arguments.contains("--clear-logins") {
        Cfg.claudeSessionKey = ""; Cfg.claudeOrgUuid = ""; Cfg.codexSessionToken = ""; Cfg.d.synchronize()
        print("cleared official logins; back to local estimate/disk."); exit(0)
    }
    if let pct = argValue("--set-week-used") {
        let sums = claudeCalibrationSums()
        guard pct > 0, pct <= 100, sums.week > 0 else { print("need 0<pct<=100 and some Claude usage (7d tokens=\(tokLabel(sums.week)))"); exit(1) }
        Cfg.claudeWeekBudget = sums.week / (pct / 100); Cfg.d.synchronize()
        print("Claude weekly calibrated: 7d=\(tokLabel(sums.week)) tok @ \(Int(pct))% used → budget \(tokLabel(Cfg.claudeWeekBudget)), shows \(100 - Int(pct))% left")
        exit(0)
    }
    if let pct = argValue("--set-5h-used") {
        let sums = claudeCalibrationSums()
        guard pct > 0, pct <= 100, sums.five > 0 else { print("need 0<pct<=100 and an active Claude 5h block (5h tokens=\(tokLabel(sums.five)))"); exit(1) }
        Cfg.claudePlan = "Custom"; Cfg.claude5hBudget = sums.five / (pct / 100); Cfg.d.synchronize()
        print("Claude 5h calibrated: 5h=\(tokLabel(sums.five)) tok @ \(Int(pct))% used → budget \(tokLabel(Cfg.claude5hBudget)), shows \(100 - Int(pct))% left")
        exit(0)
    }
    if CommandLine.arguments.contains("--once") || CommandLine.arguments.contains("--dump-config") {
        if CommandLine.arguments.contains("--dump-config") {
            print("displayMode=\(Cfg.displayMode) labels=\(Cfg.showLabels) refresh=\(Int(Cfg.refreshInterval))s")
            print("providers: Cx=\(Cfg.showCodex) Cl=\(Cfg.showClaude) Gm=\(Cfg.showGemini)")
            print("thresholds: green>\(Cfg.greenAbove) yellow>=\(Cfg.yellowAbove)")
            print("colors: high=\(Cfg.colorHigh.hexString) mid=\(Cfg.colorMid.hexString) low=\(Cfg.colorLow.hexString) unknown=\(Cfg.colorUnknown.hexString)")
            print("claude: plan=\(Cfg.claudePlan) 5h=\(tokLabel(Cfg.claude5hBudget)) week=\(tokLabel(Cfg.claudeWeekBudget))")
        }
        for p in [readCodex(), readClaude(), readGemini()] {
            var line = "\(p.name): "
            if !p.available { line += "[unavailable] \(p.problem ?? "")" }
            else {
                if let f = p.fiveHour { line += "5h=" + (f.refilled ? "refilled" : (f.stale ? "\(f.remaining ?? 0)%(stale)" : "\(f.remaining ?? 0)%")) + (f.note.map { " (\($0))" } ?? "") }
                if let w = p.weekly { line += "  \(p.name == "Claude" ? "7d" : "week")=" + (w.refilled ? "refilled" : "\(w.remaining ?? 0)%") }
                if let pl = p.plan { line += "  [\(pl)]" }
                if p.throttled { line += "  THROTTLED" }
                if let a = p.snapshotAge { line += "  (snapshot \(ageLabel(a)))" }
            }
            print(line)
        }
        exit(0)
    }
}
