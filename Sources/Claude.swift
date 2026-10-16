import Foundation

// MARK: - Claude: official usage from api.anthropic.com, signed in with Claude Code's own login

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

func fetchClaudeReading() throws -> Reading {
    let renew = "Open Claude Code once to renew it."
    guard let login = claudeLogin() else {
        throw UsageError("Not signed in to Claude Code", hint: "Run `claude` in Terminal and sign in.")
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
