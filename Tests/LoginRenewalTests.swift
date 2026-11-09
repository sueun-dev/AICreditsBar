import AppKit

/// Claude Code only renews its token while it runs, so the app starts the official CLI when the stored
/// token has expired. The CLI here is a stand-in script: the real one, and the real login, are never touched.
func runLoginRenewalTests() {
    let dir = NSTemporaryDirectory() + "aicb-renew-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let log = dir + "/calls.log"
    func script(_ name: String, _ body: String) -> String {
        let path = dir + "/" + name
        try? "#!/bin/sh\n\(body)\n".write(toFile: path, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }
    func calls() -> [String] { ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }

    // When the stored token needs renewing.
    let now = 1_800_000_000.0
    check(loginNeedsRenewal(ClaudeLogin(accessToken: "x", expiresAt: now - 5 * 3600, plan: nil), now: now), "a token that expired hours ago needs renewing")
    check(loginNeedsRenewal(ClaudeLogin(accessToken: "x", expiresAt: now + 30, plan: nil), now: now), "…and one that is about to expire, since the request could land after")
    check(!loginNeedsRenewal(ClaudeLogin(accessToken: "x", expiresAt: now + 3600, plan: nil), now: now), "a token with an hour left is fine")
    check(!loginNeedsRenewal(ClaudeLogin(accessToken: "x", expiresAt: nil, plan: nil), now: now), "a token with no expiry is left alone")

    // Finding the CLI.
    let ok = script("claude-ok", "echo \"$@\" >> '\(log)'\nexit 1")   // the exit status doesn't matter: starting up is what renews
    eq(ClaudeLoginRenewer.cliPath(environment: ["AICB_CLAUDE_BIN": ok]), ok, "an explicit path to the CLI is used")
    eq(ClaudeLoginRenewer.cliPath(environment: ["AICB_CLAUDE_BIN": dir + "/missing"]), nil, "a path that isn't there finds nothing")
    eq(ClaudeLoginRenewer.cliPath(environment: ["AICB_CLAUDE_BIN": dir + "/calls.log"]), nil, "nor does one that can't be run")

    // Running it: once, headless, no session saved, and not again for a while.
    var clock = 0.0
    let renewer = ClaudeLoginRenewer()
    check(renewer.renew(cli: ok, minimumGap: 900, timeout: 20, clock: { clock }).ran, "the CLI is run")
    eq(calls(), ["-p /status --no-session-persistence"], "headless, local command only, nothing saved")
    clock = 600
    eq(renewer.renew(cli: ok, minimumGap: 900, timeout: 20, clock: { clock }), .notDue, "not again within 15 minutes, so a login that can't be renewed isn't retried every refresh")
    eq(calls().count, 1, "…and it really didn't run")
    clock = 1000
    check(renewer.renew(cli: ok, minimumGap: 900, timeout: 20, clock: { clock }).ran, "after the gap it may try again")
    eq(calls().count, 2, "…and does")

    // Failures are contained.
    let missing = ClaudeLoginRenewer()
    eq(missing.renew(cli: nil), .noCLI, "no CLI, nothing to run")
    eq(missing.renew(cli: nil), .notDue, "…and that counts as an attempt, so it isn't reported every refresh")
    let unrunnable = ClaudeLoginRenewer().renew(cli: dir + "/calls.log", minimumGap: 0)
    check({ if case .couldNotStart = unrunnable { return true } else { return false } }(), "a file that can't be run is a failure, not a crash: \(unrunnable)")
    let slow = script("claude-slow", "exec sleep 30")
    let started = Date()
    eq(ClaudeLoginRenewer().renew(cli: slow, minimumGap: 0, timeout: 1), .timedOut(after: 1), "a CLI that hangs is stopped after the timeout")
    check(Date().timeIntervalSince(started) < 10, "…promptly")

    // What gets written down about an attempt.
    let expired = ClaudeLogin(accessToken: "old", expiresAt: now - 5 * 3600 - 24 * 60, plan: nil)
    let fresh = ClaudeLogin(accessToken: "new", expiresAt: now + 8 * 3600, plan: nil)
    eq(renewalLine(.notDue, cli: ok, before: expired, after: nil, now: now), nil, "a throttled refresh writes nothing")
    let renewed = renewalLine(.ran(seconds: 1.26), cli: ok, before: expired, after: fresh, now: now) ?? ""
    check(renewed.hasPrefix("renewed: ran \(ok) in 1.3s"), "a renewal names the CLI and how long it took: \(renewed)")
    check(renewed.contains("was: token expired 5h 24m ago"), "…how stale the token was: \(renewed)")
    check(renewed.contains("now: token valid until \(RenewalLog.stamp(now + 8 * 3600)) (8h left)"), "…and how long the new one lasts: \(renewed)")
    let unchanged = renewalLine(.ran(seconds: 0.9), cli: ok, before: expired, after: expired, now: now) ?? ""
    eq(unchanged, "ran \(ok) in 0.9s but the token did not change · token expired 5h 24m ago", "a run that renewed nothing says so")
    let soon = ClaudeLogin(accessToken: "x", expiresAt: now + 30, plan: nil)
    check(renewalLine(.ran(seconds: 1), cli: ok, before: soon, after: soon, now: now)?.contains("token valid until") == true, "a token that was only about to expire is described as still valid")
    check(renewalLine(.ran(seconds: 1), cli: ok, before: soon, after: fresh, now: now)?.hasPrefix("renewed:") == true, "…and moving its expiry out counts as renewing")
    check(renewalLine(.ran(seconds: 1), cli: ok, before: expired, after: nil, now: now)?.contains("did not change · token expired 5h 24m ago") == true, "a login that can't be read back is reported as unchanged")
    eq(renewalLine(.noCLI, cli: nil, before: expired, after: nil, now: now), "no claude CLI found (set AICB_CLAUDE_BIN or install it) · token expired 5h 24m ago", "no CLI")
    eq(renewalLine(.couldNotStart("Permission denied"), cli: ok, before: expired, after: nil, now: now), "could not start \(ok): Permission denied · token expired 5h 24m ago", "a launch failure keeps the reason")
    eq(renewalLine(.timedOut(after: 45), cli: ok, before: expired, after: expired, now: now), "\(ok) did not finish within 45s and was stopped · token expired 5h 24m ago", "a timeout")

    // The log file: one stamped line per note, oldest first, never past its size limit, never when there is no file.
    let logFile = URL(fileURLWithPath: dir + "/state/login-renewal.log")   // the folder doesn't exist yet
    let renewals = RenewalLog(file: logFile, maxBytes: 400)
    renewals.note("first", at: now)
    renewals.note("second", at: now + 61)
    var lines = ((try? String(contentsOf: logFile, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    eq(lines.count, 2, "one line per note")
    eq(lines[0], "\(RenewalLog.stamp(now))  first", "stamped with the local time, oldest first")
    eq(lines[1], "\(RenewalLog.stamp(now + 61))  second", "…then the next")
    check(lines[0].range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}  ", options: .regularExpression) != nil, "the stamp is yyyy-MM-dd HH:mm:ss: \(lines[0])")
    for i in 0..<20 { renewals.note("line \(i) " + String(repeating: "x", count: 40), at: now + Double(100 + i)) }
    let text = (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
    lines = text.split(separator: "\n").map(String.init)
    check(text.utf8.count <= 400, "trimmed to the size limit: \(text.utf8.count) bytes")
    check(lines.last?.hasSuffix("line 19 " + String(repeating: "x", count: 40)) == true, "the newest line is kept: \(lines.last ?? "")")
    check(!text.contains("  first\n"), "…the oldest ones go")
    eq(RenewalLog(file: nil).file, nil, "the tests' log has no file")
    RenewalLog(file: nil).note("nothing")
    check(!FileManager.default.fileExists(atPath: dir + "/login-renewal.log"), "…and writes nothing")
}
