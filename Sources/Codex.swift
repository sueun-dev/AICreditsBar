import Foundation

// MARK: - Codex: official usage from chatgpt.com, signed in with the Codex CLI's own login

let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? (HOME as NSString).appendingPathComponent(".codex")

struct CodexLogin {
    var accessToken: String
    var accountId: String?
}

/// The ChatGPT login the Codex CLI keeps in auth.json.
func codexLogin() throws -> CodexLogin {
    let path = (codexHome as NSString).appendingPathComponent("auth.json")
    let notSignedIn = UsageError("Not signed in to Codex", hint: "Run `codex login` in Terminal.")
    guard let root = jsonObject(FileManager.default.contents(atPath: path)) else { throw notSignedIn }
    let tokens = root["tokens"] as? [String: Any]
    guard let token = tokens?["access_token"] as? String, !token.isEmpty else {
        if let key = root["OPENAI_API_KEY"] as? String, !key.isEmpty {
            throw UsageError("Codex is signed in with an API key", hint: "API keys have no ChatGPT plan limits.")
        }
        throw notSignedIn
    }
    return CodexLogin(accessToken: token, accountId: tokens?["account_id"] as? String)
}

func fetchCodexReading() throws -> Reading {
    let login = try codexLogin()
    var headers = ["Authorization": "Bearer \(login.accessToken)", "Accept": "application/json", "User-Agent": userAgent]
    if let account = login.accountId { headers["ChatGPT-Account-Id"] = account }
    let reply = try httpGet("https://chatgpt.com/backend-api/wham/usage", headers: headers)
    switch reply.status {
    case 200: return try parseCodexUsage(reply.body, now: nowEpoch())
    case 401: throw UsageError("Codex login expired", hint: "Run `codex` once to renew it.")
    case 429: throw UsageError("chatgpt.com is rate-limiting usage checks", hint: "Checking less often until it clears.", rateLimited: true)
    default: throw UsageError("chatgpt.com answered HTTP \(reply.status)")
    }
}

/// Windows are named by their length (limit_window_seconds), never by position:
/// a Pro plan currently reports a single 7-day window as "primary".
func parseCodexUsage(_ data: Data, now: Double) throws -> Reading {
    guard let root = jsonObject(data), let limits = root["rate_limit"] as? [String: Any] else {
        throw UsageError("Unexpected reply from chatgpt.com")
    }
    let windows: [UsageWindow] = ["primary_window", "secondary_window"].compactMap { key in
        guard let window = limits[key] as? [String: Any], let used = number(window["used_percent"]) else { return nil }
        let seconds = number(window["limit_window_seconds"])
        let reset = number(window["reset_at"]) ?? number(window["reset_after_seconds"]).map { now + $0 }
        return UsageWindow(label: windowLabel(seconds: seconds), kind: windowKind(seconds: seconds),
                           usedPercent: used, resetsAt: sanitizeEpoch(reset))
    }
    guard !windows.isEmpty else { throw UsageError("chatgpt.com sent no usage limits") }

    var reading = Reading(windows: windows.sorted { $0.kind.rawValue < $1.kind.rawValue }, fetchedAt: now)
    reading.plan = (root["plan_type"] as? String).map(displayPlan)
    reading.limitReached = limits["limit_reached"] as? Bool == true || limits["allowed"] as? Bool == false
    if let credits = root["credits"] as? [String: Any] {
        if credits["unlimited"] as? Bool == true {
            reading.notes.append("Unlimited credits")
        } else if credits["has_credits"] as? Bool == true, let balance = number(credits["balance"]) {
            reading.notes.append("\(groupedNumber(balance)) credits")
        }
    }
    return reading
}
