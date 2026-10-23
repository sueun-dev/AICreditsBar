import Foundation

// MARK: - Model

enum Provider: String, CaseIterable {
    case codex = "Codex"
    case claude = "Claude"
}

/// What a usage window measures, independent of how the provider names it.
/// The raw value is the display order (short windows first).
enum WindowKind: Int, Codable {
    case session   // a few hours (Claude's 5-hour "session")
    case weekly
    case other
}

/// One rate-limit window exactly as the provider reported it.
struct UsageWindow: Equatable, Codable {
    var label: String              // "5-hour", "Weekly", "Weekly (Fable)"
    var kind: WindowKind
    var usedPercent: Double        // 0–100, as reported
    var resetsAt: Double?          // unix seconds
    var modelScoped = false        // limit for one model only; not used for the menu-bar number

    var leftPercent: Int { pctClamp(100 - usedPercent) }

    /// Once the reset time passes, the reported figure no longer describes the
    /// window. It is never assumed to be 100% — the next reading says what it is.
    func isExpired(now: Double) -> Bool { resetsAt.map { $0 <= now } ?? false }
}

/// A successful reading from a provider's official usage endpoint.
struct Reading: Codable {
    var windows: [UsageWindow]
    var plan: String?
    var limitReached = false
    var notes: [String] = []       // other official facts, e.g. "58,600 credits"
    var fetchedAt: Double
}

/// A failed refresh, worded for the menu.
struct UsageError: Error, CustomStringConvertible {
    var message: String
    var hint: String?
    var rateLimited = false   // HTTP 429: ask this provider less often for a while
    init(_ message: String, hint: String? = nil, rateLimited: Bool = false) {
        self.message = message
        self.hint = hint
        self.rateLimited = rateLimited
    }
    var description: String { hint.map { "\(message) — \($0)" } ?? message }
}

/// What the app knows about one provider: the last good reading, kept (and
/// shown as not current) when a later refresh fails, and why it failed.
struct ProviderState {
    var reading: Reading?
    var error: UsageError?
    var restored = false

    /// True when the reading is what the provider says now: the last refresh
    /// worked and it isn't old (a reading restored from the previous run is).
    func isCurrent(now: Double) -> Bool {
        guard !restored, error == nil, let reading = reading, reading.fetchedAt.isFinite else { return false }
        let age = now - reading.fetchedAt
        return age >= -5 && age < 2 * Cfg.refreshInterval + 60
    }

    /// The provider says the limit is hit — and that's still what it says now.
    func limitReached(now: Double) -> Bool { isCurrent(now: now) && reading?.limitReached == true }

    mutating func record(_ result: Result<Reading, Error>) {
        switch result {
        case .success(let reading):
            self.reading = reading
            error = nil
            restored = false
        case .failure(let failure):
            error = failure as? UsageError ?? UsageError(failure.localizedDescription)
        }
    }
}
