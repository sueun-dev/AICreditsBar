import AppKit

// Unit tests for AICreditsBar's pure logic. Built by Tests/run.sh against the
// Sources modules (minus Sources/main.swift). Exits non-zero on any failure.

var failures = 0, passed = 0
func check(_ cond: Bool, _ msg: String) {
    if cond { passed += 1 } else { failures += 1; FileHandle.standardError.write("FAIL: \(msg)\n".data(using: .utf8)!) }
}
func eq<T: Equatable>(_ a: T, _ b: T, _ msg: String) { check(a == b, "\(msg): got \(a), want \(b)") }
func approx(_ a: Double, _ b: Double, _ msg: String, eps: Double = 1e-6) { check(abs(a - b) < eps, "\(msg): got \(a), want \(b)") }

// ---- time / formatting ----
check(parseISO("2026-06-06T01:56:42.865Z") != nil, "parseISO fractional")
check(parseISO("2026-06-06T01:56:42Z") != nil, "parseISO no-frac")
check(parseISO("not-a-date") == nil, "parseISO rejects garbage")
let ep = parseISO("2026-06-06T01:56:42Z")!
eq(floorToHour(ep), parseISO("2026-06-06T01:00:00Z")!, "floorToHour drops minutes")
eq(tokLabel(1_500_000), "1.5M", "tokLabel millions")
eq(tokLabel(2300), "2K", "tokLabel thousands")
eq(tokLabel(1_200_000_000), "1200.0M", "tokLabel billions as M")
eq(resetLabel(nowEpoch() - 100), "now", "resetLabel past → now")
eq(ageLabel(30), "just now", "ageLabel recent")

// ---- color hex roundtrip ----
let green = NSColor(hex: "#30D158")!
eq(green.hexString, "#30D158", "color hex roundtrip")
check(NSColor(hex: "zzzzzz") == nil, "color hex rejects non-hex")
check(NSColor(hex: "#FFF") == nil, "color hex rejects short")

// ---- digRateLimits ----
let rlJSON = #"{"payload":{"rate_limits":{"primary":{"used_percent":42.0,"resets_at":123},"secondary":{"used_percent":71.0}}}}"#.data(using: .utf8)!
let rl = digRateLimits(try! JSONSerialization.jsonObject(with: rlJSON))
check(rl != nil, "digRateLimits finds the rate_limits object")
check((rl?["primary"] as? [String: Any])?["used_percent"] as? Double == 42.0, "digRateLimits reads primary used_percent")

// ---- Claude 5h block + weekly ----
let now = nowEpoch()
let block = currentClaudeBlock([(now - 1000, 10_000_000), (now - 400, 5_000_000)])
check(block != nil && block!.active, "currentClaudeBlock active for recent events")
approx(block!.tokens, 15_000_000, "block sums recent tokens")
check(currentClaudeBlock([]) == nil, "currentClaudeBlock nil for no events")
let idle = currentClaudeBlock([(now - 8 * 3600, 9_000_000)])
check(idle != nil && !idle!.active, "currentClaudeBlock inactive when last event > 5h ago")
approx(claudeWeekTokens([(now - 1000, 3_000_000), (now - 8 * 86400, 9_000_000)]), 3_000_000, "claudeWeekTokens excludes >7d")

// ---- tailLines reads the tail of a file ----
let tmp = NSTemporaryDirectory() + "aicb-unit-\(ProcessInfo.processInfo.processIdentifier).txt"
let lines = (0..<5000).map { "line \($0) \($0 % 7 == 0 ? "MARK" : "x")" }.joined(separator: "\n")
try! lines.write(toFile: tmp, atomically: true, encoding: .utf8)
let matched = tailLines(tmp, must: "MARK", maxBytes: 4096)
check(!matched.isEmpty, "tailLines returns matches")
check(matched.allSatisfy { $0.contains("MARK") }, "tailLines filters by substring")
check(matched.last!.contains("4998"), "tailLines includes the final matching line (EOF)")
try? FileManager.default.removeItem(atPath: tmp)

// ---- rendering text ----
eq(windowText(WindowStat(remaining: 54)), "54%", "windowText percent")
eq(windowText(WindowStat(remaining: 100, refilled: true)), "↑", "windowText refilled glyph")
eq(windowText(nil), "?", "windowText nil → ?")

// ---- official cache: throttle + no flapping ----
var fetches = 0
func goodFetch() -> ProviderStatus { fetches += 1; var s = ProviderStatus(key: "T", name: "T", available: true); s.fiveHour = WindowStat(remaining: 73); return s }
func locFetch() -> ProviderStatus { var s = ProviderStatus(key: "T", name: "T", available: true); s.fiveHour = WindowStat(remaining: 12); return s }
func badFetch() -> ProviderStatus { ProviderStatus(key: "T", name: "T", available: false) }
clearOfficial("UT")
let oc1 = officialOrCached("UT", fetch: goodFetch, fallback: locFetch, fallbackNote: { _ in "fb" })
eq(oc1.fiveHour?.remaining, 73, "official success returns the official value")
eq(fetches, 1, "fetched exactly once")
let oc2 = officialOrCached("UT", fetch: goodFetch, fallback: locFetch, fallbackNote: { _ in "fb" })
eq(oc2.fiveHour?.remaining, 73, "within TTL returns cached value (no flap)")
eq(fetches, 1, "no re-fetch within TTL (no hammering)")
clearOfficial("UT2")
let oc3 = officialOrCached("UT2", fetch: badFetch, fallback: locFetch, fallbackNote: { _ in "fb-note" })
eq(oc3.fiveHour?.remaining, 12, "failure with no cache → fallback value")
check(oc3.details.first == "fb-note", "fallback note is prepended on failure")

// ---- resetLabel sub-minute ----
eq(resetLabel(nowEpoch() + 30), "in <1m", "resetLabel sub-minute is 'in <1m', not 'in 0m'")

// ---- barInfo never substitutes the other window in single-window modes ----
func prov(_ f: Int?, _ w: Int?) -> ProviderStatus {
    var s = ProviderStatus(key: "Cx", name: "T", available: true)
    if let f = f { s.fiveHour = WindowStat(remaining: f) }
    if let w = w { s.weekly = WindowStat(remaining: w) }
    return s
}
Cfg.displayMode = "week"
eq(barInfo(prov(54, nil)).0, "?", "week mode → '?' when weekly absent (no 5h substitution)")
eq(barInfo(prov(54, 31)).0, "31%", "week mode shows weekly")
Cfg.displayMode = "5h"
eq(barInfo(prov(nil, 70)).0, "?", "5h mode → '?' when 5h absent (no weekly substitution)")
eq(barInfo(prov(88, 70)).0, "88%", "5h mode shows 5h")
Cfg.displayMode = "both"
eq(barInfo(prov(88, nil)).0, "88%/?", "both mode shows f/? when weekly absent")

// ---- colorFor tolerates inverted thresholds (mid stays reachable) ----
Cfg.greenAbove = 20; Cfg.yellowAbove = 50
eq(colorFor(WindowStat(remaining: 35)).hexString, Cfg.colorMid.hexString, "inverted thresholds: mid still reachable at 35%")
Cfg.resetAll()

// ---- malformed external values and expired observations ----
eq(resetLabel(Double.greatestFiniteMagnitude), "?", "absurd reset must not trap converting to Int")
eq(ageLabel(.infinity), "?", "infinite age rejected")
eq(sanitizeEpoch(-1), nil, "negative reset rejected")
eq(pctClamp(-1e300), 0, "huge negative percentage clamped before conversion")
eq(pctClamp(1e300), 100, "huge positive percentage clamped before conversion")
Cfg.refreshInterval = .nan
eq(Cfg.refreshInterval, 15, "invalid refresh interval falls back to automatic cadence")
Cfg.resetAll()
var expired = prov(8, 44)
expired.fiveHour?.resetEpoch = nowEpoch() - 1
expired.snapshotAge = 2
let aged = expired.aged(by: 8)
eq(aged.fiveHour?.remaining, 8, "clock crossing reset never invents 100%")
eq(aged.fiveHour?.stale, true, "expired window waits for a new reading")
eq(aged.snapshotAge, 10, "snapshot age advances without network")
eq(aged.fiveHour?.refilled, false, "expired snapshot is not confirmed refilled")

// ---- forced refresh, backoff, held stale cache ----
_ = officialOrCached("UT", force: true, fetch: goodFetch, fallback: locFetch, fallbackNote: { _ in "fb" })
eq(fetches, 2, "manual refresh bypasses a fresh cache")
var failedFetches = 0
clearOfficial("FAIL")
for _ in 0..<4 {
    _ = officialOrCached("FAIL", fetch: { failedFetches += 1; return badFetch() }, fallback: locFetch, fallbackNote: { _ in "fb" })
}
eq(failedFetches, 1, "automatic failures back off instead of hammering API")
_ = officialOrCached("FAIL", force: true, fetch: { failedFetches += 1; return badFetch() }, fallback: locFetch, fallbackNote: { _ in "fb" })
eq(failedFetches, 2, "manual retry bypasses failure backoff")
storeOfficial("HELD", expired)
let held = officialOrCached("HELD", force: true, fetch: badFetch, fallback: locFetch, fallbackNote: { _ in "fb" })
eq(held.fiveHour?.remaining, 8, "failed refresh keeps actual last quota after reset")
eq(held.fiveHour?.refilled, false, "failed refresh cannot claim refill")
eq(held.weekly?.stale, true, "held weekly quota is visibly stale")
let heldAgain = officialOrCached("HELD", fetch: goodFetch, fallback: locFetch, fallbackNote: { _ in "fb" })
eq(heldAgain.weekly?.stale, true, "cache hit after failed manual retry keeps the stale notice")
clearOfficial("INVALIDATED")
_ = officialOrCached("INVALIDATED", fetch: { clearOfficial("INVALIDATED"); return goodFetch() }, fallback: locFetch, fallbackNote: { _ in "fb" })
eq(cachedOfficial("INVALIDATED")?.status.fiveHour?.remaining, nil, "in-flight result cannot repopulate cache after login changes")

// ---- real run-loop timers read changed files with NO manual refresh ----
func pump(until condition: () -> Bool, timeout: Double = 3) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
}
let liveFile = NSTemporaryDirectory() + "aicb-live-\(UUID().uuidString).txt"
try! "81".write(toFile: liveFile, atomically: true, encoding: .utf8)
let automatic = RefreshController(readers: [.init(key: "T", fetch: { _ in
    let value = Int((try? String(contentsOfFile: liveFile)) ?? "")
    return prov(value, nil)
})])
var readings: [Int] = []
automatic.onUpdate = { if let value = $0.fiveHour?.remaining { readings.append(value) } }
automatic.start(interval: 0.05)
pump(until: { readings.contains(81) })
try! "27".write(toFile: liveFile, atomically: true, encoding: .utf8)
pump(until: { readings.contains(27) })
automatic.stop()
check(readings.contains(81) && readings.contains(27), "timer alone publishes changed disk values")
try? FileManager.default.removeItem(atPath: liveFile)

// A deliberately blocked provider cannot block the fast provider; repeated
// automatic ticks must not accumulate requests behind the blocked read.
let releaseSlow = DispatchSemaphore(value: 0)
let slowLock = NSLock(); var slowCalls = 0
let independent = RefreshController(readers: [
    .init(key: "slow", fetch: { _ in
        slowLock.lock(); slowCalls += 1; slowLock.unlock()
        _ = releaseSlow.wait(timeout: .now() + 3)
        return ProviderStatus(key: "slow", name: "Slow", available: true)
    }),
    .init(key: "fast", fetch: { _ in ProviderStatus(key: "fast", name: "Fast", available: true) })
])
var receivedKeys: [String] = []
independent.onUpdate = { receivedKeys.append($0.key) }
independent.start(interval: 0.05)
pump(until: { receivedKeys.filter { $0 == "fast" }.count >= 3 })
check(receivedKeys.contains("fast") && !receivedKeys.contains("slow"), "fast provider updates while another request is blocked")
independent.stop()
slowLock.lock(); let callsBeforeRelease = slowCalls; slowLock.unlock()
eq(callsBeforeRelease, 1, "automatic ticks never overlap the same provider")
releaseSlow.signal()
pump(until: { receivedKeys.contains("slow") })
check(receivedKeys.contains("slow"), "slow provider eventually publishes its own result")

// Forced requests coalesce to one follow-up and obsolete results are discarded.
let releaseForce = DispatchSemaphore(value: 0)
let forcedLock = NSLock(); var forcedCalls = 0
let forced = RefreshController(readers: [.init(key: "forced", fetch: { force in
    forcedLock.lock(); forcedCalls += 1; let index = forcedCalls; forcedLock.unlock()
    if index == 1 { _ = releaseForce.wait(timeout: .now() + 3) }
    return prov(force ? 92 : 10, nil)
})])
var forcedValues: [Int] = []
forced.onUpdate = { if let value = $0.fiveHour?.remaining { forcedValues.append(value) } }
forced.refresh()
for _ in 0..<10 { forced.refresh(force: true) }
releaseForce.signal()
pump(until: { forcedValues.contains(92) })
eq(forcedValues, [92], "forced refresh discards obsolete in-flight reading")
forcedLock.lock(); let totalForced = forcedCalls; forcedLock.unlock()
eq(totalForced, 2, "ten forced requests coalesce to one follow-up")

let summary = "\(passed) passed, \(failures) failed"
print(failures == 0 ? "✓ unit: \(summary)" : "✗ unit: \(summary)")
exit(failures == 0 ? 0 : 1)
