import Foundation

// MARK: - Claude: usage from api.anthropic.com (the endpoint Claude Code uses), signed in with Claude Code's own login

let claudeConfigDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? (HOME as NSString).appendingPathComponent(".claude")

struct ClaudeLogin {
    var accessToken: String
    var expiresAt: Double?   // unix seconds
    var plan: String?
}

/// Claude Code keeps its login in the Keychain ("Claude Code-credentials");
/// some setups use ~/.claude/.credentials.json instead.
func claudeLogin() -> ClaudeLogin? {
    let useKeychain = ProcessInfo.processInfo.environment["AICB_SKIP_KEYCHAIN"] == nil   // tests run without the real login
    if useKeychain, let login = parseClaudeLogin(keychainSecret(service: "Claude Code-credentials")) { return login }
    let file = (claudeConfigDir as NSString).appendingPathComponent(".credentials.json")
    return parseClaudeLogin(FileManager.default.contents(atPath: file))
}

/// Already expired, or about to be: a request would be rejected before it was answered.
func loginNeedsRenewal(_ login: ClaudeLogin, now: Double) -> Bool {
    login.expiresAt.map { $0 <= now + 60 } ?? false
}

func parseClaudeLogin(_ data: Data?) -> ClaudeLogin? {
    guard let oauth = jsonObject(data)?["claudeAiOauth"] as? [String: Any],
          let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
    return ClaudeLogin(accessToken: token,
                       expiresAt: number(oauth["expiresAt"]).map { $0 / 1000 },   // stored in milliseconds
                       plan: claudePlanName(subscription: oauth["subscriptionType"] as? String,
                                            tier: oauth["rateLimitTier"] as? String))
}

/// "default_claude_max_20x" → "Max 20x"; otherwise the subscription ("pro" → "Pro").
func claudePlanName(subscription: String?, tier: String?) -> String? {
    let tier = tier?.lowercased() ?? ""
    if tier.contains("max_20x") { return "Max 20x" }
    if tier.contains("max_5x") { return "Max 5x" }
    guard let subscription = subscription, !subscription.isEmpty else { return nil }
    return displayPlan(subscription)
}

/// Claude Code renews its access token (about every 8 hours) only while it is running. Someone who
/// works in another surface — the desktop app, an editor — can stay signed in for days with a stored
/// token that has long expired. Starting the official CLI headlessly makes it renew and store its own
/// token; this app never reads or uses the refresh token, and a nonexistent CLI or a failed renewal
/// just leaves the usual "login expired" message.
/// What one attempt came to. Whether it actually renewed the login is in the Keychain afterwards.
enum RenewalAttempt: Equatable {
    case ran(seconds: Double)      // the CLI started and ended on its own
    case notDue                    // an attempt was made less than `minimumGap` ago
    case noCLI                     // nothing to run
    case couldNotStart(String)
    case timedOut(after: Double)
    var ran: Bool { if case .ran = self { return true } else { return false } }
}

final class ClaudeLoginRenewer {
    static let shared = ClaudeLoginRenewer()
    private let lock = NSLock()
    private var lastAttempt = -Double.infinity

    /// Where the CLI usually is; the LaunchAgent's PATH is too short to find it by name.
    static func cliPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let forced = environment["AICB_CLAUDE_BIN"] { return FileManager.default.isExecutableFile(atPath: forced) ? forced : nil }
        var candidates = ["\(HOME)/.local/bin/claude", "\(HOME)/.claude/local/claude", "/opt/homebrew/bin/claude",
                          "/usr/local/bin/claude", "\(HOME)/.npm-global/bin/claude", "\(HOME)/.bun/bin/claude"]
        candidates += (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/claude" }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs the CLI once, at most every `minimumGap` seconds (a missing CLI counts as an attempt, so it
    /// isn't reported every refresh). The caller reads the stored login again to see whether that renewed
    /// it. Blocks: call off the main thread.
    func renew(cli: String? = ClaudeLoginRenewer.cliPath(), minimumGap: TimeInterval = 900, timeout: TimeInterval = 45,
               clock: () -> Double = { Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1e9 }) -> RenewalAttempt {
        lock.lock()
        let now = clock()
        guard now - lastAttempt >= minimumGap else { lock.unlock(); return .notDue }
        lastAttempt = now
        lock.unlock()
        guard let cli = cli else { return .noCLI }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        // A command it can't run still starts it up, and starting up is what renews the token;
        // nothing is sent to the model and no session is saved.
        process.arguments = ["-p", "/status", "--no-session-persistence"]
        process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return .couldNotStart(error.localizedDescription) }
        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return .timedOut(after: timeout)
        }
        return .ran(seconds: clock() - now)
    }
}

/// One line per renewal attempt, so whether the app really renewed a login can be checked afterwards:
/// ~/Library/Application Support/AICreditsBar/login-renewal.log, oldest first, trimmed to the newest lines.
final class RenewalLog {
    static let shared = RenewalLog(file: RenewalLog.defaultFile)

    /// Tests set AICB_DEFAULTS_SUITE; they never write the real log.
    static var defaultFile: URL? {
        if ProcessInfo.processInfo.environment["AICB_DEFAULTS_SUITE"] != nil { return nil }
        let directory = ProcessInfo.processInfo.environment["AICB_STATE_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("AICreditsBar")
        return directory?.appendingPathComponent("login-renewal.log")
    }

    let file: URL?
    let maxBytes: Int
    private let lock = NSLock()

    init(file: URL?, maxBytes: Int = 64 * 1024) {
        self.file = file
        self.maxBytes = maxBytes
    }

    func note(_ message: String, at time: Double = nowEpoch()) {
        guard let file = file else { return }
        lock.lock(); defer { lock.unlock() }
        var text = ((try? String(contentsOf: file, encoding: .utf8)) ?? "") + "\(Self.stamp(time))  \(message)\n"
        // Over the limit, drop the oldest lines down to half of it, so the file stays small and trims rarely.
        if text.utf8.count > maxBytes {
            while text.utf8.count > maxBytes / 2, let newline = text.firstIndex(of: "\n"), newline < text.index(before: text.endIndex) {
                text = String(text[text.index(after: newline)...])
            }
        }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: file, atomically: true, encoding: .utf8)
    }

    /// "2026-11-07 02:40:12", local time.
    static func stamp(_ time: Double) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date(timeIntervalSince1970: time))
    }
}

/// The log line for one attempt: what ran, and whether the stored token moved. Nil when nothing was tried.
func renewalLine(_ attempt: RenewalAttempt, cli: String?, before: ClaudeLogin, after: ClaudeLogin?, now: Double) -> String? {
    func state(_ login: ClaudeLogin?) -> String {
        guard let expiry = login?.expiresAt else { return "token has no expiry" }
        return expiry <= now ? "token expired \(durationText(now - expiry)) ago"
                             : "token valid until \(RenewalLog.stamp(expiry)) (\(durationText(expiry - now)) left)"
    }
    let name = cli ?? "the CLI"
    switch attempt {
    case .notDue: return nil
    case .noCLI: return "no claude CLI found (set AICB_CLAUDE_BIN or install it) · \(state(before))"
    case .couldNotStart(let reason): return "could not start \(name): \(reason) · \(state(before))"
    case .timedOut(let limit): return "\(name) did not finish within \(Int(limit))s and was stopped · \(state(after ?? before))"
    case .ran(let seconds):
        let took = String(format: "%.1fs", seconds)
        let renewed = (after?.expiresAt ?? -.infinity) > now && (after?.expiresAt ?? -.infinity) > (before.expiresAt ?? -.infinity)
        return renewed ? "renewed: ran \(name) in \(took) · was: \(state(before)) · now: \(state(after))"
                       : "ran \(name) in \(took) but the token did not change · \(state(after ?? before))"
    }
}

func fetchClaudeReading() throws -> Reading {
    let renew = "Open Claude Code once to renew it."
    guard var login = claudeLogin() else {
        throw UsageError("Not signed in to Claude Code", hint: "Run `claude` in Terminal and sign in.")
    }
    if loginNeedsRenewal(login, now: nowEpoch()) {
        // Tests run without the real login, and must not start the real CLI either.
        let allowed = ProcessInfo.processInfo.environment["AICB_SKIP_KEYCHAIN"] == nil || ProcessInfo.processInfo.environment["AICB_CLAUDE_BIN"] != nil
        if allowed {
            let cli = ClaudeLoginRenewer.cliPath()
            let attempt = ClaudeLoginRenewer.shared.renew(cli: cli)
            let fresh = attempt == .notDue ? nil : claudeLogin()
            if let line = renewalLine(attempt, cli: cli, before: login, after: fresh, now: nowEpoch()) { RenewalLog.shared.note(line) }
            if let fresh = fresh { login = fresh }
        }
    }
    if let expiry = login.expiresAt, expiry <= nowEpoch() { throw UsageError("Claude Code login expired", hint: renew) }
    let reply = try httpGet("https://api.anthropic.com/api/oauth/usage", headers: [
        "Authorization": "Bearer \(login.accessToken)", "anthropic-beta": "oauth-2025-04-20",
        "Accept": "application/json", "User-Agent": userAgent])
    switch reply.status {
    case 200: return try parseClaudeUsage(reply.body, plan: login.plan, now: nowEpoch())
    case 401: throw UsageError("Claude Code login was rejected", hint: "Open Claude Code and sign in again.")
    case 429: throw UsageError("Anthropic is rate-limiting usage checks", hint: "Checking less often until it clears.", rateLimited: true)
    default: throw UsageError("api.anthropic.com answered HTTP \(reply.status)")
    }
}

/// The same numbers Claude Code's /usage shows. Reads the `limits` list (which
/// includes per-model weekly limits) and falls back to the older per-window fields.
func parseClaudeUsage(_ data: Data, plan: String?, now: Double) throws -> Reading {
    guard let root = jsonObject(data) else { throw UsageError("Unexpected reply from api.anthropic.com") }
    var windows: [UsageWindow] = []
    if let limits = root["limits"] as? [[String: Any]], !limits.isEmpty {
        for limit in limits {
            guard let used = number(limit["percent"]) else { continue }
            let kindName = limit["kind"] as? String ?? ""
            let (label, kind) = claudeWindowName(kind: kindName, group: limit["group"] as? String)
            let scoped = limit["scope"] is [String: Any] || kindName.contains("scoped")   // applies to one model only
            windows.append(UsageWindow(label: scoped ? "\(label) (\(claudeScopeName(limit["scope"]) ?? "one model"))" : label,
                                       kind: kind, usedPercent: used,
                                       resetsAt: sanitizeEpoch(parseISO(limit["resets_at"] as? String ?? "")),
                                       modelScoped: scoped))
        }
    } else {
        let legacy: [(key: String, label: String, kind: WindowKind, scoped: Bool)] = [
            ("five_hour", "5-hour", .session, false), ("seven_day", "Weekly", .weekly, false),
            ("seven_day_opus", "Weekly (Opus)", .weekly, true), ("seven_day_sonnet", "Weekly (Sonnet)", .weekly, true)]
        for field in legacy {
            guard let window = root[field.key] as? [String: Any], let used = number(window["utilization"]) else { continue }
            windows.append(UsageWindow(label: field.label, kind: field.kind, usedPercent: used,
                                       resetsAt: sanitizeEpoch(parseISO(window["resets_at"] as? String ?? "")),
                                       modelScoped: field.scoped))
        }
    }
    guard !windows.isEmpty else { throw UsageError("api.anthropic.com sent no usage limits") }

    var reading = Reading(windows: windows, fetchedAt: now)
    reading.plan = plan
    reading.limitReached = windows.contains { !$0.modelScoped && $0.usedPercent >= 100 }
    return reading
}

private func claudeWindowName(kind: String?, group: String?) -> (String, WindowKind) {
    let kind = kind ?? "", group = group ?? ""
    if kind == "session" || group == "session" { return ("5-hour", .session) }
    if group == "weekly" || kind.hasPrefix("weekly") { return ("Weekly", .weekly) }
    return (kind.isEmpty ? "Usage limit" : kind.replacingOccurrences(of: "_", with: " ").capitalized, .other)
}

/// The model (or surface) a limit is restricted to, e.g. "Fable".
private func claudeScopeName(_ scope: Any?) -> String? {
    guard let scope = scope as? [String: Any] else { return nil }
    for key in ["model", "surface"] {
        if let named = scope[key] as? [String: Any] {
            for field in ["display_name", "id"] { if let name = named[field] as? String, !name.isEmpty { return name } }
        }
        if let name = scope[key] as? String, !name.isEmpty { return name }
    }
    return nil
}
