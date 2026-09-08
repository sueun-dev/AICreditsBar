import AppKit

// MARK: - Model

struct WindowStat {
    var remaining: Int?        // percent remaining (0-100), nil = unknown
    var resetEpoch: Double?    // unix seconds when window resets
    var refilled: Bool = false // reserved for a confirmed refill, never inferred from a clock alone
    var stale: Bool = false    // snapshot too old to trust (window not yet reset)
    var note: String?
}

struct ProviderStatus {
    var key: String
    var name: String
    var available: Bool
    var fiveHour: WindowStat?
    var weekly: WindowStat?
    var plan: String?
    var snapshotAge: Double?
    var throttled: Bool = false
    var details: [String] = []
    var problem: String?
    var source: UsageSource = .local
}

enum UsageSource: String {
    case official = "Official"
    case local = "Local snapshot"
    case estimate = "Estimate"
    case statusOnly = "Connection only"
}

extension ProviderStatus {
    // Age a reading without inventing new quota after a scheduled reset.
    func aged(by elapsed: Double) -> ProviderStatus {
        var result = self
        if let age = snapshotAge { result.snapshotAge = max(0, age + elapsed) }
        func ageWindow(_ window: WindowStat?) -> WindowStat? {
            guard var window = window else { return nil }
            if let reset = window.resetEpoch, reset <= nowEpoch() {
                window.stale = true; window.refilled = false
            }
            return window
        }
        result.fiveHour = ageWindow(fiveHour); result.weekly = ageWindow(weekly)
        return result
    }
}
