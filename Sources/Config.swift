import Foundation

// MARK: - Settings (UserDefaults, with defaults)

enum Cfg {
    // Tests set AICB_DEFAULTS_SUITE to an isolated suite so they never touch the real settings.
    static let d: UserDefaults = {
        if let suite = ProcessInfo.processInfo.environment["AICB_DEFAULTS_SUITE"], let defaults = UserDefaults(suiteName: suite) {
            return defaults
        }
        return .standard
    }()

    private static func int(_ key: String, _ fallback: Int) -> Int { d.object(forKey: key) == nil ? fallback : d.integer(forKey: key) }

    /// Which window the menu bar shows: "min" (lowest remaining), "5h" or "week".
    static var displayMode: String {
        get { let mode = d.string(forKey: "displayMode") ?? ""; return ["5h", "week"].contains(mode) ? mode : "min" }
        set { d.set(newValue, forKey: "displayMode") }
    }

    static func isShown(_ provider: Provider) -> Bool { d.object(forKey: "show\(provider.rawValue)") as? Bool ?? true }
    static func setShown(_ provider: Provider, _ shown: Bool) { d.set(shown, forKey: "show\(provider.rawValue)") }

    /// Seconds between automatic checks. The usage endpoints rate-limit hard, so
    /// the default is 5 minutes (the menu also checks when it opens).
    static var refreshInterval: Double {
        get { let value = d.double(forKey: "refreshInterval"); return value.isFinite && value > 0 ? min(3600, max(60, value)) : 300 }
        set { d.set(newValue, forKey: "refreshInterval") }
    }

    /// Remaining % below which the number turns orange / red.
    static var warnBelow: Int {
        get { min(100, max(0, int("warnBelow", 30))) }
        set { d.set(newValue, forKey: "warnBelow") }
    }
    static var criticalBelow: Int {
        get { min(100, max(0, int("criticalBelow", 10))) }
        set { d.set(newValue, forKey: "criticalBelow") }
    }

    /// The last good reading per provider, so a restart shows it (with its age) right away.
    static func savedReading(_ provider: Provider) -> Reading? {
        d.data(forKey: "lastReading\(provider.rawValue)").flatMap { try? JSONDecoder().decode(Reading.self, from: $0) }
    }
    static func save(_ reading: Reading, for provider: Provider) {
        d.set(try? JSONEncoder().encode(reading), forKey: "lastReading\(provider.rawValue)")
    }

    /// Version 1 settings and logins nothing reads any more — among them a claude.ai
    /// session cookie, which shouldn't sit around in plain text.
    static func removeLegacyKeys() {
        for key in ["claudeSessionKey", "codexSessionToken", "claudeOrgUuid", "claudePlan", "claude5hBudget",
                    "claudeWeekBudget", "showGemini", "showLabels", "greenAbove", "yellowAbove",
                    "colorHigh", "colorMid", "colorLow", "colorUnknown"] {
            d.removeObject(forKey: key)
        }
    }

    static func resetAll() {
        for key in ["displayMode", "showCodex", "showClaude", "refreshInterval", "warnBelow", "criticalBelow"] {
            d.removeObject(forKey: key)
        }
    }
}
