import Foundation

struct QuotaAlert: Equatable {
    enum Kind: String { case low, recovered }
    var kind: Kind
    var provider: Provider
    var window: String
    var left: Int
    var id: String

    var title: String {
        kind == .low ? "\(provider.rawValue): \(left)% remaining" : "\(provider.rawValue) quota recovered"
    }
    var body: String {
        kind == .low ? "\(window) is at or below 20%." : "\(window) now has \(left)% remaining, confirmed by a new usage reading."
    }
}

/// Pure transition detector. Only successful, fresh readings enter this path;
/// clock passage, restored snapshots and failures cannot generate a recovery.
struct QuotaAlertTracker {
    struct Checkpoint: Codable {
        var used: Double
        var reset: Double?
        var observedAt: Double
        var lowNotified: Bool
        var cycle: UInt64
        var pendingRecovery: Bool
    }
    private(set) var checkpoints: [String: Checkpoint]

    init(data: Data? = nil) {
        checkpoints = data.flatMap { try? JSONDecoder().decode([String: Checkpoint].self, from: $0) } ?? [:]
    }
    var data: Data? { try? JSONEncoder().encode(checkpoints) }

    mutating func observe(_ reading: Reading, provider: Provider, now: Double,
                          lowEnabled: Bool, recoveryEnabled: Bool) -> [QuotaAlert] {
        guard reading.fetchedAt.isFinite, reading.fetchedAt <= now + 5,
              now - reading.fetchedAt <= 60 else { return [] }
        let prefix = provider.rawValue + ":"
        var alerts: [QuotaAlert] = []
        var present = Set<String>()
        for window in reading.windows {
            let key = prefix + "\(window.kind.rawValue):\(window.modelScoped):\(window.label)"
            // Ambiguous duplicate windows cannot independently drive notifications.
            guard present.insert(key).inserted else { continue }
            guard window.usedPercent.isFinite, (0...100).contains(window.usedPercent),
                  !window.isExpired(now: now) else { continue }
            let previous = checkpoints[key].flatMap { $0.observedAt <= now + 5 ? $0 : nil }
            if let previous = previous, reading.fetchedAt <= previous.observedAt { continue }
            let newCycle: Bool
            if let oldReset = previous?.reset, let reset = window.resetsAt {
                newCycle = now >= oldReset && reset > oldReset + 1
            } else { newCycle = false }
            let recovered = previous.map {
                window.usedPercent < $0.used && (newCycle || ($0.used >= 100 && window.usedPercent < 100))
            } ?? false
            var cycle = previous?.cycle ?? 0
            let unknownRefill = previous?.reset == nil && window.resetsAt == nil && (previous?.used ?? 0) >= 100 && window.usedPercent == 0
            if newCycle || unknownRefill { cycle &+= 1 }
            let lowNotified = (newCycle || unknownRefill) ? false : (previous?.lowNotified ?? false)
            let pendingRecovery = recoveryEnabled && window.usedPercent < 100
                && (recovered || (!newCycle && (previous?.pendingRecovery ?? false)))
            if pendingRecovery {
                alerts.append(QuotaAlert(kind: .recovered, provider: provider, window: window.label,
                                         left: window.leftPercent, id: "\(key):recovered:\(cycle)"))
            }
            // Use the reported value, not the rounded display (20.4% is still >20%).
            if window.usedPercent >= 80, !lowNotified {
                if lowEnabled {
                    alerts.append(QuotaAlert(kind: .low, provider: provider, window: window.label,
                                             left: window.leftPercent, id: "\(key):low:\(cycle)"))
                }
            }
            checkpoints[key] = Checkpoint(used: window.usedPercent, reset: window.resetsAt,
                                          observedAt: reading.fetchedAt, lowNotified: lowNotified, cycle: cycle,
                                          pendingRecovery: pendingRecovery)
        }
        // Bound persistence to the windows in this provider's latest response.
        checkpoints = checkpoints.filter { !$0.key.hasPrefix(prefix) || present.contains($0.key) }
        return alerts
    }

    /// Only a successful OS scheduling callback consumes an alert. A denied
    /// permission or delivery error leaves it retryable on the next fresh reading.
    mutating func acknowledge(_ alert: QuotaAlert) {
        for key in checkpoints.keys {
            guard let checkpoint = checkpoints[key], alert.id == "\(key):\(alert.kind.rawValue):\(checkpoint.cycle)" else { continue }
            if alert.kind == .low { checkpoints[key]?.lowNotified = true }
            else { checkpoints[key]?.pendingRecovery = false }
        }
    }
}
