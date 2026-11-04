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

    static var lowAlerts: Bool {
        get { d.object(forKey: "lowAlerts") as? Bool ?? true }
        set { d.set(newValue, forKey: "lowAlerts") }
    }
    static var recoveryAlerts: Bool {
        get { d.object(forKey: "recoveryAlerts") as? Bool ?? true }
        set { d.set(newValue, forKey: "recoveryAlerts") }
    }
    static var checkForUpdates: Bool {
        get { d.object(forKey: "checkForUpdates") as? Bool ?? true }
        set { d.set(newValue, forKey: "checkForUpdates") }
    }
    static var alertHistory: Data? {
        get { d.data(forKey: "alertHistory") }
        set { if newValue != alertHistory { d.set(newValue, forKey: "alertHistory") } }
    }
    /// Readings of the current cycle, kept to measure how fast a limit is being used.
    static var usageHistory: Data? {
        get { d.data(forKey: "usageHistory") }
        set { if newValue != usageHistory { d.set(newValue, forKey: "usageHistory") } }
    }

    // Forecast and model advice (estimates; the reported numbers are never changed).
    static var forecastEnabled: Bool {
        get { d.object(forKey: "forecastEnabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "forecastEnabled") }
    }
    /// The model your pace was spent on; advice is relative to it.
    static var mainModel: ModelFamily {
        get { ModelFamily(rawValue: d.string(forKey: "mainModel") ?? "") ?? .sonnet }
        set { d.set(newValue.rawValue, forKey: "mainModel") }
    }
    static var modelVersion: String {
        get {
            let value = (d.string(forKey: "modelVersion") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? "5.5" : String(value.prefix(8))
        }
        set { d.set(newValue, forKey: "modelVersion") }
    }
    static func modelWeight(_ model: ModelFamily) -> Double {
        let value = d.double(forKey: "modelWeight\(model.rawValue)")
        return value.isFinite && value > 0 ? min(100, max(0.1, value)) : model.defaultWeight
    }
    static func setModelWeight(_ model: ModelFamily, _ value: Double) { d.set(value, forKey: "modelWeight\(model.rawValue)") }
    static var forecastSettings: ForecastSettings {
        ForecastSettings(baseline: mainModel, version: modelVersion,
                         weights: Dictionary(uniqueKeysWithValues: ModelFamily.allCases.map { ($0, modelWeight($0)) }))
    }

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
        for key in ["displayMode", "showCodex", "showClaude", "refreshInterval", "warnBelow", "criticalBelow", "lowAlerts", "recoveryAlerts", "checkForUpdates",
                    "forecastEnabled", "mainModel", "modelVersion"] + ModelFamily.allCases.map({ "modelWeight\($0.rawValue)" }) {
            d.removeObject(forKey: key)
        }
    }
}
