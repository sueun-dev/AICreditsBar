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
    check(renewer.renew(cli: ok, minimumGap: 900, timeout: 20, clock: { clock }), "the CLI is run")
    eq(calls(), ["-p /status --no-session-persistence"], "headless, local command only, nothing saved")
    clock = 600
    check(!renewer.renew(cli: ok, minimumGap: 900, timeout: 20, clock: { clock }), "not again within 15 minutes, so a login that can't be renewed isn't retried every refresh")
    eq(calls().count, 1, "…and it really didn't run")
    clock = 1000
    check(renewer.renew(cli: ok, minimumGap: 900, timeout: 20, clock: { clock }), "after the gap it may try again")
    eq(calls().count, 2, "…and does")

    // Failures are contained.
    check(!ClaudeLoginRenewer().renew(cli: nil), "no CLI, nothing to run")
    check(!ClaudeLoginRenewer().renew(cli: dir + "/calls.log", minimumGap: 0), "a file that can't be run is a failure, not a crash")
    let slow = script("claude-slow", "exec sleep 30")
    let started = Date()
    check(!ClaudeLoginRenewer().renew(cli: slow, minimumGap: 0, timeout: 1), "a CLI that hangs is stopped after the timeout")
    check(Date().timeIntervalSince(started) < 10, "…promptly")
}
