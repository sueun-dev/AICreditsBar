import AppKit

// MARK: - Config (UserDefaults-backed, with defaults)

enum Cfg {
    // Defaults store. Tests/e2e set AICB_DEFAULTS_SUITE to an isolated suite so they
    // never read or clobber the real user's settings/tokens.
    static let d: UserDefaults = {
        if let s = ProcessInfo.processInfo.environment["AICB_DEFAULTS_SUITE"], let u = UserDefaults(suiteName: s) { return u }
        return .standard
    }()
    static func dbl(_ k: String, _ def: Double) -> Double { d.object(forKey: k) == nil ? def : d.double(forKey: k) }
    static func int(_ k: String, _ def: Int) -> Int { d.object(forKey: k) == nil ? def : d.integer(forKey: k) }
    static func bool(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) == nil ? def : d.bool(forKey: k) }
    static func color(_ k: String, _ def: NSColor) -> NSColor {
        if let s = d.string(forKey: k), let c = NSColor(hex: s) { return c }; return def
    }
    static func validBudget(_ v: Double, _ def: Double) -> Double { (v.isFinite && v >= 1 && v <= 1e15) ? v : def }

    static var displayMode: String { get { d.string(forKey: "displayMode") ?? "5h" } set { d.set(newValue, forKey: "displayMode") } }   // 5h | week | both | min
    static var showCodex: Bool  { get { bool("showCodex", true) }  set { d.set(newValue, forKey: "showCodex") } }
    static var showClaude: Bool { get { bool("showClaude", true) } set { d.set(newValue, forKey: "showClaude") } }
    static var showGemini: Bool { get { bool("showGemini", true) } set { d.set(newValue, forKey: "showGemini") } }
    static var showLabels: Bool { get { bool("showLabels", true) } set { d.set(newValue, forKey: "showLabels") } }
    static var refreshInterval: Double { get { min(3600, max(5, dbl("refreshInterval", 30))) } set { d.set(newValue, forKey: "refreshInterval") } }
    static var greenAbove: Int { get { int("greenAbove", 50) } set { d.set(newValue, forKey: "greenAbove") } }
    static var yellowAbove: Int { get { int("yellowAbove", 20) } set { d.set(newValue, forKey: "yellowAbove") } }
    static var colorHigh: NSColor { get { color("colorHigh", .systemGreen) }  set { d.set(newValue.hexString, forKey: "colorHigh") } }
    static var colorMid: NSColor  { get { color("colorMid", .systemYellow) }  set { d.set(newValue.hexString, forKey: "colorMid") } }
    static var colorLow: NSColor  { get { color("colorLow", .systemRed) }     set { d.set(newValue.hexString, forKey: "colorLow") } }
    static var colorUnknown: NSColor { get { color("colorUnknown", .secondaryLabelColor) } set { d.set(newValue.hexString, forKey: "colorUnknown") } }
    static var claude5hBudget: Double { get { validBudget(dbl("claude5hBudget", 220_000_000), 220_000_000) } set { d.set(newValue, forKey: "claude5hBudget") } }
    static var claudeWeekBudget: Double { get { validBudget(dbl("claudeWeekBudget", 1_500_000_000), 1_500_000_000) } set { d.set(newValue, forKey: "claudeWeekBudget") } }
    static var claudePlan: String { get { d.string(forKey: "claudePlan") ?? "Max 20x" } set { d.set(newValue, forKey: "claudePlan") } }
    // Official web-session tokens (exact %, like usage4claude). Empty = use local estimate/disk.
    // Stored in UserDefaults (no keychain prompt for an ad-hoc-built app). Local, revocable session cookies.
    static var claudeSessionKey: String { get { d.string(forKey: "claudeSessionKey") ?? "" } set { d.set(newValue, forKey: "claudeSessionKey") } }
    static var codexSessionToken: String { get { d.string(forKey: "codexSessionToken") ?? "" } set { d.set(newValue, forKey: "codexSessionToken") } }
    static var claudeOrgUuid: String { get { d.string(forKey: "claudeOrgUuid") ?? "" } set { d.set(newValue, forKey: "claudeOrgUuid") } }

    static let planBudgets: [String: Double] = ["Pro": 19_000_000, "Max 5x": 88_000_000, "Max 20x": 220_000_000]

    static func resetAll() {
        for k in ["displayMode","showCodex","showClaude","showGemini","showLabels","refreshInterval",
                  "greenAbove","yellowAbove","colorHigh","colorMid","colorLow","colorUnknown",
                  "claude5hBudget","claudeWeekBudget","claudePlan"] { d.removeObject(forKey: k) }
    }
}

extension NSColor {
    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02X%02X%02X", Int(round(c.redComponent*255)), Int(round(c.greenComponent*255)), Int(round(c.blueComponent*255)))
    }
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces); if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = Int(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v>>16)&0xFF)/255, green: CGFloat((v>>8)&0xFF)/255, blue: CGFloat(v&0xFF)/255, alpha: 1)
    }
}
