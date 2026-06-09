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

let summary = "\(passed) passed, \(failures) failed"
print(failures == 0 ? "✓ unit: \(summary)" : "✗ unit: \(summary)")
exit(failures == 0 ? 0 : 1)
