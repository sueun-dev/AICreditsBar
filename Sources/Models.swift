import AppKit

// MARK: - Model

struct WindowStat {
    var remaining: Int?        // percent remaining (0-100), nil = unknown
    var resetEpoch: Double?    // unix seconds when window resets
    var refilled: Bool = false // window's scheduled reset has passed -> fresh quota
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
}
