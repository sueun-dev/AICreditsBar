// Exercise the production default clock with simulated OS clocks. Sleeping
// advances continuous time but not uptime; the real Mac is never put to sleep.
import Foundation
import Darwin

enum SimulatedClock {
    static var uptime = 1_000.0
    static var continuous = 1_000.0
    static func advance(awake: Double, asleep: Double) {
        uptime += awake
        continuous += awake + asleep
    }
}

// These module-local stand-ins replace the platform clock APIs only in this
// isolated executable. RefreshController's clock argument is left at its default.
struct ProcessInfo {
    static let processInfo = ProcessInfo()
    var systemUptime: Double { SimulatedClock.uptime }
}
func clock_gettime_nsec_np(_ clock: clockid_t) -> UInt64 {
    precondition(clock == CLOCK_MONOTONIC_RAW || clock == CLOCK_UPTIME_RAW)
    return UInt64((clock == CLOCK_MONOTONIC_RAW ? SimulatedClock.continuous : SimulatedClock.uptime) * 1e9)
}

enum Provider { case codex, claude }
struct Reading {}
struct UsageError: Error { var rateLimited: Bool }
func fetchCodexReading() throws -> Reading { fatalError("Use the offline fixture") }
func fetchClaudeReading() throws -> Reading { fatalError("Use the offline fixture") }

var failures = 0
func check(_ condition: Bool, _ label: String) {
    print("\(condition ? "ok" : "FAIL"): \(label)")
    if !condition { failures += 1 }
}
func pump(until done: () -> Bool, timeout: TimeInterval = 1) {
    let end = Date().addingTimeInterval(timeout)
    while !done() && Date() < end {
        RunLoop.main.run(until: Date().addingTimeInterval(0.005))
    }
}

var completed = 0
let ordinary = RefreshController(sources: [.init(provider: .codex, fetch: { Reading() })])
ordinary.onResult = { _, _ in completed += 1 }
ordinary.refresh()
pump(until: { completed == 1 })
check(completed == 1, "initial request completes")
SimulatedClock.advance(awake: 1, asleep: 3_600)
ordinary.refresh(minimumGap: 30)
pump(until: { completed == 2 })
check(completed == 2, "an hour asleep satisfies the wake refresh's minimum gap")

var limited = 0
let backoff = RefreshController(sources: [.init(provider: .claude, fetch: {
    throw UsageError(rateLimited: true)
})])
backoff.onResult = { _, _ in limited += 1 }
backoff.refresh()
pump(until: { limited == 1 })
check(limited == 1, "HTTP 429 starts a five-minute backoff")
SimulatedClock.advance(awake: 1, asleep: 238)
backoff.refresh()
pump(until: { false }, timeout: 0.05)
check(limited == 1, "a short sleep does not bypass the remaining backoff")
SimulatedClock.advance(awake: 1, asleep: 60)
backoff.refresh()
pump(until: { limited == 2 })
check(limited == 2, "backoff expires after five minutes including sleep")
exit(failures == 0 ? 0 : 1)
