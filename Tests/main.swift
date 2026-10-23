import AppKit

// Unit tests for AICreditsBar. Built by Tests/run.sh together with Sources/
// (minus Sources/main.swift). Exits non-zero on any failure.

var failures = 0, passed = 0
func check(_ condition: Bool, _ message: String) {
    if condition { passed += 1 } else { failures += 1; FileHandle.standardError.write("FAIL: \(message)\n".data(using: .utf8)!) }
}
func eq<T: Equatable>(_ actual: T, _ expected: T, _ message: String) { check(actual == expected, "\(message): got \(actual), want \(expected)") }
func approx(_ actual: Double?, _ expected: Double, _ message: String, tolerance: Double = 0.01) {
    check(actual.map { abs($0 - expected) < tolerance } ?? false, "\(message): got \(String(describing: actual)), want \(expected)")
}
func throwsError(_ body: () throws -> Any, _ message: String) {
    do { _ = try body(); check(false, "\(message): expected an error") } catch { passed += 1 }
}
let now = 1_792_172_000.0   // 2026-10-16T17:33:20Z, shortly before the replies below were captured

// MARK: Codex — real chatgpt.com reply for a Pro account (identifiers removed)

let codexPro = #"""
{"plan_type":"pro","rate_limit":{"allowed":true,"limit_reached":false,
 "primary_window":{"used_percent":5,"limit_window_seconds":604800,"reset_after_seconds":503074,"reset_at":1792675822},
 "secondary_window":null},"code_review_rate_limit":null,"additional_rate_limits":null,
 "credits":{"has_credits":true,"unlimited":false,"overage_limit_reached":false,"balance":"58600.4837255000",
 "approx_local_messages":[14650,76181],"approx_cloud_messages":[2344,14650]},
 "spend_control":{"reached":false,"individual_limit":null},"rate_limit_reached_type":null,"promo":null}
"""#.data(using: .utf8)!

let pro = try! parseCodexUsage(codexPro, now: now)
eq(pro.windows.count, 1, "Pro reports a single window")
eq(pro.windows[0].label, "Weekly", "a 604800 s primary window is the weekly one, not 5-hour")
eq(pro.windows[0].kind, .weekly, "weekly kind")
eq(pro.windows[0].leftPercent, 95, "5% used → 95% left")
eq(pro.windows[0].resetsAt, 1792675822, "absolute reset_at wins")
eq(pro.plan, "Pro", "plan name")
eq(pro.notes, ["58,600 credits"], "credit balance from the string field")
eq(pro.limitReached, false, "not limited")

let codexSwapped = #"""
{"plan_type":"plus","rate_limit":{"limit_reached":true,
 "primary_window":{"used_percent":40,"limit_window_seconds":604800,"reset_after_seconds":3600},
 "secondary_window":{"used_percent":100,"limit_window_seconds":18000,"reset_after_seconds":600}}}
"""#.data(using: .utf8)!
let swapped = try! parseCodexUsage(codexSwapped, now: now)
eq(swapped.windows.map { $0.label }, ["5-hour", "Weekly"], "windows named by length and listed short first")
eq(swapped.windows.map { $0.leftPercent }, [0, 60], "percent per window")
eq(swapped.windows[1].resetsAt, now + 3600, "relative reset_after_seconds")
eq(swapped.limitReached, true, "limit_reached")
eq(swapped.notes, [], "no credits block → no note")

throwsError({ try parseCodexUsage("<html>Just a moment...</html>".data(using: .utf8)!, now: now) }, "HTML is rejected")
throwsError({ try parseCodexUsage(#"{"rate_limit":{"primary_window":null,"secondary_window":null}}"#.data(using: .utf8)!, now: now) }, "no windows is an error, not 100%")

// MARK: Claude — real api.anthropic.com/api/oauth/usage reply (Max 20x)

let claudeMax = #"""
{"five_hour":{"utilization":8.0,"resets_at":"2026-10-16T20:20:00.359697+00:00","limit_dollars":null},
 "seven_day":{"utilization":43.0,"resets_at":"2026-10-17T14:00:00.359725+00:00","limit_dollars":null},
 "seven_day_oauth_apps":null,"seven_day_opus":null,"seven_day_sonnet":null,
 "extra_usage":{"is_enabled":false,"monthly_limit":null,"used_credits":null,"utilization":null},
 "limits":[
  {"kind":"session","group":"session","percent":8,"severity":"normal","resets_at":"2026-10-16T20:20:00.359697+00:00","scope":null,"is_active":false},
  {"kind":"weekly_all","group":"weekly","percent":43,"severity":"normal","resets_at":"2026-10-17T14:00:00.359725+00:00","scope":null,"is_active":true},
  {"kind":"weekly_scoped","group":"weekly","percent":6,"severity":"normal","resets_at":"2026-10-17T14:00:00.359984+00:00",
   "scope":{"model":{"id":null,"display_name":"Fable"},"surface":null},"is_active":false}]}
"""#.data(using: .utf8)!

let max20 = try! parseClaudeUsage(claudeMax, plan: "Max 20x", now: now)
eq(max20.windows.map { $0.label }, ["5-hour", "Weekly", "Weekly (Fable)"], "every limit, including the per-model one")
eq(max20.windows.map { $0.leftPercent }, [92, 57, 94], "percent left per limit")
eq(max20.windows.map { $0.modelScoped }, [false, false, true], "only the Fable limit is model-scoped")
eq(max20.windows.map { $0.kind }, [.session, .weekly, .weekly], "kinds")
approx(max20.windows[0].resetsAt, 1792182000.36, "microsecond ISO timestamps parse")
eq(max20.plan, "Max 20x", "plan from the login")
eq(max20.limitReached, false, "not limited")

let claudeLegacy = #"{"five_hour":{"utilization":100,"resets_at":"2026-10-16T20:20:00Z"},"seven_day":{"utilization":12.5,"resets_at":null},"seven_day_opus":{"utilization":30,"resets_at":null}}"#.data(using: .utf8)!
let legacy = try! parseClaudeUsage(claudeLegacy, plan: nil, now: now)
eq(legacy.windows.map { $0.label }, ["5-hour", "Weekly", "Weekly (Opus)"], "older reply shape still read")
eq(legacy.windows.map { $0.leftPercent }, [0, 88, 70], "12.5% used rounds to 88% left")
eq(legacy.windows[1].resetsAt, nil, "missing reset stays unknown")
eq(legacy.limitReached, true, "a full general window means the limit is reached")

let scopedFull = #"{"limits":[{"kind":"weekly_all","group":"weekly","percent":50},{"kind":"weekly_scoped","group":"weekly","percent":100,"scope":{"model":{"display_name":"Fable"}}}]}"#.data(using: .utf8)!
eq(try! parseClaudeUsage(scopedFull, plan: nil, now: now).limitReached, false, "a full per-model limit doesn't block other models")
throwsError({ try parseClaudeUsage(#"{"five_hour":null,"seven_day":null}"#.data(using: .utf8)!, plan: nil, now: now) }, "no limits is an error")
throwsError({ try parseClaudeUsage(Data(), plan: nil, now: now) }, "empty body is an error")

// MARK: Claude Code login

let keychainJSON = #"{"claudeAiOauth":{"accessToken":"sk-ant-oat01-x","refreshToken":"r","expiresAt":1792192009285,"scopes":["user:profile"],"subscriptionType":"max","rateLimitTier":"default_claude_max_20x"},"mcpOAuth":{}}"#
let login = parseClaudeLogin(keychainJSON.data(using: .utf8))
eq(login?.accessToken, "sk-ant-oat01-x", "token")
approx(login?.expiresAt, 1792192009.285, "expiresAt is milliseconds")
eq(login?.plan, "Max 20x", "plan from the rate-limit tier")
check(parseClaudeLogin(#"{"claudeAiOauth":{"accessToken":""}}"#.data(using: .utf8)) == nil, "empty token → no login")
check(parseClaudeLogin("not json".data(using: .utf8)) == nil, "garbage → no login")
check(parseClaudeLogin(nil) == nil, "missing → no login")
eq(claudePlanName(subscription: "max", tier: "default_claude_max_5x"), "Max 5x", "Max 5x")
eq(claudePlanName(subscription: "pro", tier: "default_claude_pro"), "Pro", "Pro")
eq(claudePlanName(subscription: nil, tier: nil), nil, "unknown plan stays unknown")

// MARK: Labels and formatting

eq(windowLabel(seconds: 18000), "5-hour", "18000 s")
eq(windowLabel(seconds: 604800), "Weekly", "604800 s")
eq(windowLabel(seconds: 86400), "Daily", "86400 s")
eq(windowLabel(seconds: 2_592_000), "30-day", "30 days")
eq(windowLabel(seconds: nil), "Usage limit", "unknown length")
eq(windowKind(seconds: 18000), .session, "5h kind")
eq(windowKind(seconds: 604800), .weekly, "weekly kind")
eq(windowKind(seconds: 2_592_000), .other, "monthly kind")
eq(countdown(to: now + 30, now: now), "in <1m", "under a minute")
eq(countdown(to: now + 45 * 60, now: now), "in 45m", "minutes")
eq(countdown(to: now + 2 * 3600 + 31 * 60 + 59, now: now), "in 2h 31m", "hours and minutes")
eq(countdown(to: now + 5 * 86400 + 19 * 3600 + 7, now: now), "in 5d 19h", "days and hours")
eq(ago(5), "just now", "fresh")
eq(ago(4 * 60 + 59), "4m ago", "minutes ago")
eq(ago(3 * 3600), "3h ago", "hours ago")
eq(ago(-30), "just now", "clock skew is not negative time")
eq(groupedNumber(58600.48), "58,600", "grouped, rounded down")
eq(displayPlan("pro"), "Pro", "plan capitalised")
eq(pctClamp(.nan), 0, "NaN never traps")
eq(pctClamp(1e300), 100, "huge value clamped before Int()")
eq(pctClamp(-1e300), 0, "huge negative value clamped")
eq(sanitizeEpoch(-1), nil, "negative epoch dropped")
eq(sanitizeEpoch(.infinity), nil, "infinite epoch dropped")
eq(number("58600.48"), 58600.48, "numeric string")
eq(number("abc"), nil, "non-numeric string")
approx(parseISO("2026-10-16T20:19:59.571730Z"), 1792181999.571, "Z with microseconds")

// MARK: Menu-bar number

func window(_ label: String, _ kind: WindowKind, used: Double, resets: Double? = nil, scoped: Bool = false) -> UsageWindow {
    UsageWindow(label: label, kind: kind, usedPercent: used, resetsAt: resets, modelScoped: scoped)
}
let mixed = Reading(windows: [window("5-hour", .session, used: 20), window("Weekly", .weekly, used: 45),
                              window("Weekly (Fable)", .weekly, used: 90, scoped: true)], fetchedAt: now)
Cfg.resetAll()
eq(menuBarWindow(mixed, now: now)?.label, "Weekly", "lowest remaining ignores the per-model limit")
Cfg.displayMode = "5h"
eq(menuBarWindow(mixed, now: now)?.label, "5-hour", "5-hour mode")
eq(menuBarWindow(pro, now: now)?.label, "Weekly", "no 5-hour window → the tightest real limit, not '?'")
Cfg.displayMode = "week"
eq(menuBarWindow(mixed, now: now)?.label, "Weekly", "weekly mode skips the per-model weekly")
Cfg.displayMode = "both"   // a value from version 1
eq(Cfg.displayMode, "min", "unknown mode falls back to lowest remaining")

let expiredFiveHour = Reading(windows: [window("5-hour", .session, used: 97, resets: now - 1), window("Weekly", .weekly, used: 30)], fetchedAt: now)
eq(menuBarWindow(expiredFiveHour, now: now)?.label, "Weekly", "a window past its reset no longer counts as the lowest")
Cfg.displayMode = "5h"
eq(menuBarGauge(ProviderState(reading: expiredFiveHour), now: now).left, nil, "past reset → empty ring, never an invented 100%")
Cfg.resetAll()

eq(menuBarGauge(ProviderState(), now: now).text, "…", "first check in progress")
eq(menuBarGauge(ProviderState(reading: nil, error: UsageError("x")), now: now).text, "—", "no data → '—', empty ring")
eq(menuBarGauge(ProviderState(reading: mixed), now: now), MenuBarGauge(left: 55, level: .normal, isCurrent: true), "lowest remaining, current")
eq(menuBarGauge(ProviderState(reading: mixed, error: UsageError("offline")), now: now).isCurrent, false, "last good reading is marked not current")
let low = Reading(windows: [window("Weekly", .weekly, used: 75)], fetchedAt: now)
let critical = Reading(windows: [window("Weekly", .weekly, used: 95)], fetchedAt: now)
eq(menuBarGauge(ProviderState(reading: low), now: now).level, .warning, "25% left → orange ring")
eq(menuBarGauge(ProviderState(reading: critical), now: now).level, .critical, "5% left → red ring")
let rings = menuBarImage([(.codex, ProviderState(reading: pro)), (.claude, ProviderState(reading: max20))], appearance: NSAppearance(named: .darkAqua)!, now: now)
eq(rings.size, NSSize(width: 19 + 6 + 19, height: 19), "two compact rings, no numbers in the menu bar")
eq(rings.accessibilityDescription, "Codex 95%, Claude 57%", "rings still read out the numbers")
Cfg.warnBelow = 5; Cfg.criticalBelow = 50   // swapped by the user
eq(level(forLeft: 30), .warning, "swapped thresholds still order correctly")
Cfg.resetAll()

// MARK: Settings defaults

eq(Cfg.displayMode, "min", "default display")
eq(Cfg.refreshInterval, 300, "default check interval: 5 minutes")
Cfg.refreshInterval = 5
eq(Cfg.refreshInterval, 60, "interval floor protects the rate-limited APIs")
Cfg.refreshInterval = .nan
eq(Cfg.refreshInterval, 300, "invalid interval → default")
check(Cfg.isShown(.codex) && Cfg.isShown(.claude), "both providers on by default")
Cfg.setShown(.claude, false)
check(!Cfg.isShown(.claude), "provider toggle")
Cfg.resetAll()

// MARK: State and report

var state = ProviderState()
state.record(.success(pro))
state.record(.failure(UsageError("Can't reach chatgpt.com")))
eq(state.reading?.windows.first?.leftPercent, 95, "a failed refresh keeps the last good reading")
eq(state.error?.message, "Can't reach chatgpt.com", "…and says why it isn't current")
state.record(.success(pro))
check(state.error == nil, "the next success clears the error")
eq(describe(.codex, state, now: now), "Codex · Pro\n  Weekly   95% left  resets in 5d 19h\n  58,600 credits", "--once report")
eq(describe(.claude, ProviderState(reading: nil, error: UsageError("Not signed in to Claude Code", hint: "Run `claude`.")), now: now),
   "Claude: Not signed in to Claude Code — Run `claude`.", "--once error report")
eq(ProviderCardView.height(for: ProviderState(reading: max20)), 66 + 3 * 36, "card grows with the window count")
check(ProviderState(reading: max20).isCurrent(now: now + 60), "a fresh reading is current")
check(!ProviderState(reading: max20).isCurrent(now: now + 3 * 3600), "a reading restored from hours ago is not current")
eq(menuBarGauge(ProviderState(reading: pro), now: now + 3 * 3600).isCurrent, false, "…so its ring is faded")
Cfg.save(max20, for: .claude)
eq(Cfg.savedReading(.claude)?.windows, max20.windows, "last reading survives a restart")
eq(Cfg.savedReading(.codex)?.windows, nil, "nothing saved → nothing restored")

// MARK: Refresh controller (real run-loop timers)

func pump(until condition: () -> Bool, timeout: Double = 3) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
}
func reading(left: Int) -> Reading { Reading(windows: [window("Weekly", .weekly, used: Double(100 - left))], fetchedAt: nowEpoch()) }

let liveFile = NSTemporaryDirectory() + "aicb-live-\(UUID().uuidString).txt"
try! "81".write(toFile: liveFile, atomically: true, encoding: .utf8)
let timed = RefreshController(sources: [.init(provider: .codex, fetch: {
    reading(left: Int((try? String(contentsOfFile: liveFile)) ?? "") ?? 0)
})])
var seen: [Int] = []
timed.onResult = { _, result in if let left = (try? result.get())?.windows.first?.leftPercent { seen.append(left) } }
timed.start(every: 0.05)
pump(until: { seen.contains(81) })
try! "27".write(toFile: liveFile, atomically: true, encoding: .utf8)
pump(until: { seen.contains(27) })
timed.stop()
check(seen.contains(81) && seen.contains(27), "the timer alone picks up new values")
try? FileManager.default.removeItem(atPath: liveFile)

// A blocked provider can't hold up the other, and its requests never pile up.
let release = DispatchSemaphore(value: 0)
let lock = NSLock(); var slowCalls = 0
let independent = RefreshController(sources: [
    .init(provider: .claude, fetch: {
        lock.lock(); slowCalls += 1; lock.unlock()
        _ = release.wait(timeout: .now() + 3)
        return reading(left: 1)
    }),
    .init(provider: .codex, fetch: { reading(left: 2) })])
var arrivals: [Provider] = []
independent.onResult = { provider, _ in arrivals.append(provider) }
independent.start(every: 0.05)
pump(until: { arrivals.filter { $0 == .codex }.count >= 3 })
check(arrivals.contains(.codex) && !arrivals.contains(.claude), "fast provider updates while the other is blocked")
independent.stop()
lock.lock(); let blockedCalls = slowCalls; lock.unlock()
eq(blockedCalls, 1, "no overlapping requests for one provider")
release.signal()
pump(until: { arrivals.contains(.claude) })
check(arrivals.contains(.claude), "the slow provider still reports")

var fetched = 0
let gated = RefreshController(sources: [.init(provider: .codex, fetch: { reading(left: 3) })])
gated.onResult = { _, _ in fetched += 1 }
gated.isEnabled = { _ in false }
gated.refresh()
gated.isEnabled = { _ in true }
gated.refresh(minimumGap: 20)
pump(until: { fetched == 1 }, timeout: 0.3)
eq(fetched, 1, "a skipped disabled provider does not throttle its first enabled refresh")
gated.refresh(minimumGap: 20)
pump(until: { false }, timeout: 0.05)
eq(fetched, 1, "minimumGap is tracked per provider's actual request")

// After an HTTP 429 the provider is left alone (no matter how often refresh is asked for);
// other providers carry on, and other errors don't pause anything.
var limitedCalls = 0, otherCalls = 0
let limited = RefreshController(sources: [
    .init(provider: .claude, fetch: { throw UsageError("429", rateLimited: true) }),
    .init(provider: .codex, fetch: { throw UsageError("offline") })])
var limitedResults = 0
limited.onResult = { provider, _ in
    limitedResults += 1
    if provider == .claude { limitedCalls += 1 } else { otherCalls += 1 }
}
for _ in 0..<5 {
    let before = limitedResults
    let expected = limitedCalls == 0 ? 2 : 1
    limited.refresh()
    pump(until: { limitedResults >= before + expected }, timeout: 1)
}
eq(limitedCalls, 1, "a rate-limited provider isn't asked again during its pause")
eq(otherCalls, 5, "a plain failure doesn't pause the other provider")

// Results and timers must also arrive while the menu is open (event-tracking run-loop mode).
_ = NSApplication.shared   // as in the app: AppKit adds event tracking to the run loop's common modes
var tracked = 0
let tracking = RefreshController(sources: [.init(provider: .codex, fetch: { reading(left: 64) })])
tracking.onResult = { _, _ in tracked += 1 }
tracking.start(every: 0.05)
let trackingDeadline = Date().addingTimeInterval(2)
while tracked < 3 && Date() < trackingDeadline { RunLoop.main.run(mode: .eventTracking, before: Date().addingTimeInterval(0.01)) }
tracking.stop()
check(tracked >= 3, "updates keep coming while the menu is open")

// MARK: Review regressions

let unnamedScopes = #"""
{"limits":[{"kind":"weekly_all","group":"weekly","percent":40},
 {"kind":"weekly_scoped","group":"weekly","percent":100,"scope":{"model":{"id":null,"display_name":null},"surface":null}},
 {"kind":"weekly_scoped","group":"weekly","percent":10,"scope":{"model":{"id":"claude-fable-5-1","display_name":null}}}]}
"""#.data(using: .utf8)!
let unnamed = try! parseClaudeUsage(unnamedScopes, plan: nil, now: now)
eq(unnamed.windows.map { $0.label }, ["Weekly", "Weekly (one model)", "Weekly (claude-fable-5-1)"], "per-model limits stay per-model without a display name")
eq(unnamed.windows.map { $0.modelScoped }, [false, true, true], "…and stay out of the ring")
eq(unnamed.limitReached, false, "a full per-model limit doesn't block everything")

eq(windowLabel(seconds: 1e30), "Usage limit", "absurd window length doesn't trap")
check(!groupedNumber(1e300).isEmpty, "huge credit balance doesn't trap")
let absurd = #"{"rate_limit":{"primary_window":{"used_percent":5,"limit_window_seconds":1e30,"reset_at":1e30}}}"#.data(using: .utf8)!
eq(try! parseCodexUsage(absurd, now: now).windows.first?.label, "Usage limit", "absurd Codex reply parses without crashing")

var limitedState = ProviderState(reading: swapped)   // the reply said limit_reached
check(limitedState.limitReached(now: now + 60), "current reading: limit reached")
check(!limitedState.limitReached(now: now + 3 * 3600), "hours-old reading no longer claims it")
limitedState.error = UsageError("offline")
check(!limitedState.limitReached(now: now + 60), "failing refresh: no claim")

eq(describe(.claude, ProviderState(reading: expiredFiveHour), now: now),
   "Claude\n  5-hour     —       reset passed, awaiting a new reading\n  Weekly   70% left  no reset time",
   "--once never prints a % for a window past its reset")

// Settings: a number typed without Return is kept when Done closes the window.
Cfg.resetAll()
let settingsWindow = SettingsWindow()
let settingsPNG = NSTemporaryDirectory() + "aicb-settings-\(UUID().uuidString).png"
try? settingsWindow.renderToPNG(settingsPNG)   // builds the window offscreen
try? FileManager.default.removeItem(atPath: settingsPNG)
settingsWindow.window?.makeFirstResponder(settingsWindow.warnField)
settingsWindow.warnField.currentEditor()?.string = "45"
settingsWindow.closeWindow()
eq(Cfg.warnBelow, 45, "Done keeps a value typed without pressing Return")
Cfg.resetAll()

Cfg.d.set("secret", forKey: "claudeSessionKey")
Cfg.d.set("org", forKey: "claudeOrgUuid")
Cfg.removeLegacyKeys()
check(Cfg.d.object(forKey: "claudeSessionKey") == nil && Cfg.d.object(forKey: "claudeOrgUuid") == nil, "version-1 session cookie is removed")

runRegressionTests(now: now)
runNotificationTests(now: now)

let summary = "\(passed) passed, \(failures) failed"
print(failures == 0 ? "✓ unit: \(summary)" : "✗ unit: \(summary)")
exit(failures == 0 ? 0 : 1)
