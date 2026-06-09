import AppKit

// MARK: - Codex (exact official %)

let CODEX_STALE: Double = 90 * 60   // snapshot older than this (window not yet reset) -> show as stale

func readCodexLocal() -> ProviderStatus {
    var st = ProviderStatus(key: "Cx", name: "Codex", available: false)
    let base = (HOME as NSString).appendingPathComponent(".codex/sessions")
    guard FileManager.default.fileExists(atPath: base) else { st.problem = "not installed (~/.codex/sessions absent)"; return st }
    let files = Array(filesByMtime(under: base, suffix: ".jsonl").prefix(20))
    var bestEpoch = -Double.infinity   // so a record even without a parseable timestamp is still usable
    var best: [String: Any]? = nil
    for f in files {
        for line in tailLines(f.path, must: "\"rate_limits\"") {     // tail-read so huge append-only files aren't skipped
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data),
                  let rl = digRateLimits(obj) else { continue }
            let ep = parseISO(((obj as? [String: Any])?["timestamp"] as? String) ?? "") ?? -1
            if ep > bestEpoch { bestEpoch = ep; best = rl }       // freshest by parsed epoch, not raw string
        }
    }
    guard let rl = best else { st.problem = "no usage yet — run codex once"; return st }
    st.available = true
    st.plan = rl["plan_type"] as? String
    let age: Double? = bestEpoch > 0 ? nowEpoch() - bestEpoch : nil
    st.snapshotAge = age
    func win(_ k: String) -> WindowStat? {
        guard let w = rl[k] as? [String: Any], let used = (w["used_percent"] as? NSNumber)?.doubleValue else { return nil }
        let reset = (w["resets_at"] as? NSNumber)?.doubleValue
        let refilled = reset.map { $0 <= nowEpoch() } ?? false      // missing reset -> NOT refilled
        let stale = !refilled && (age ?? 0) > CODEX_STALE
        return WindowStat(remaining: refilled ? 100 : max(0, min(100, Int((100 - used).rounded()))),
                          resetEpoch: reset, refilled: refilled, stale: stale)
    }
    st.fiveHour = win("primary")
    st.weekly = win("secondary")
    let rr = rl["rate_limit_reached_type"]
    let throttledRaw = rr != nil && !(rr is NSNull)
    st.throttled = throttledRaw && !(st.fiveHour?.refilled ?? false)   // a refilled window can't be throttled
    return st
}

// MARK: - Claude (token estimate; cached per-file events)

final class EventCache {
    private var cache: [String: (mtime: Double, size: Int, events: [(Double, Double, String)])] = [:]
    private let lock = NSLock()
    func get(_ path: String, mtime: Double, size: Int) -> [(Double, Double, String)]? {
        lock.lock(); defer { lock.unlock() }
        if let c = cache[path], c.mtime == mtime, c.size == size { return c.events }; return nil
    }
    func put(_ path: String, mtime: Double, size: Int, _ ev: [(Double, Double, String)]) {
        lock.lock(); defer { lock.unlock() }; cache[path] = (mtime, size, ev)
    }
}
let claudeCache = EventCache()

func parseClaudeFile(_ path: String) -> [(Double, Double, String)] {   // (epoch, totalTokens, dedupKey)
    var out: [(Double, Double, String)] = []
    // tailLines (not grepLines) so an enormous single session file isn't dropped whole —
    // that would wrongly show "100% / idle". Claude jsonl is append-only; freshest events at EOF.
    for line in tailLines(path, must: "\"usage\"", maxBytes: 256_000_000) {
        guard line.contains("\"assistant\"") else { continue }      // cheap reject before JSON parse
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["type"] as? String) == "assistant",
              (obj["isSidechain"] as? Bool) != true,
              let msg = obj["message"] as? [String: Any],
              let u = msg["usage"] as? [String: Any],
              let tsS = obj["timestamp"] as? String, let ep = parseISO(tsS) else { continue }
        func n(_ k: String) -> Double { (u[k] as? NSNumber)?.doubleValue ?? 0 }
        let tot = n("input_tokens") + n("output_tokens") + n("cache_creation_input_tokens") + n("cache_read_input_tokens")
        out.append((ep, tot, "\(msg["id"] ?? "")|\(obj["requestId"] ?? "")"))
    }
    return out
}

// Dedup'd (epoch, tokens) assistant events over the last ~7 days, sorted ascending.
func gatherClaudeEvents() -> [(Double, Double)] {
    let base = (HOME as NSString).appendingPathComponent(".claude/projects")
    guard FileManager.default.fileExists(atPath: base) else { return [] }
    let horizon = nowEpoch() - 7*86400 - 3600
    let files = filesByMtime(under: base, suffix: ".jsonl", newerThan: horizon).filter { !$0.path.contains("/subagents/") }
    var raw: [(Double, Double, String)] = []
    for f in files {
        let ev = claudeCache.get(f.path, mtime: f.mtime, size: f.size) ?? {
            let parsed = parseClaudeFile(f.path); claudeCache.put(f.path, mtime: f.mtime, size: f.size, parsed); return parsed
        }()
        raw.append(contentsOf: ev)
    }
    var seen = Set<String>(); var events: [(Double, Double)] = []
    for (ep, tot, key) in raw { if key != "|", seen.contains(key) { continue }; seen.insert(key); events.append((ep, tot)) }
    events.sort { $0.0 < $1.0 }
    return events
}
struct ClaudeBlock { var tokens: Double; var reset: Double; var firstEp: Double; var active: Bool }
// Current 5-hour rolling block (ccusage-style) over the full event list.
func currentClaudeBlock(_ events: [(Double, Double)]) -> ClaudeBlock? {
    guard !events.isEmpty else { return nil }
    let FIVE = 5.0 * 3600
    struct Blk { var start: Double; var firstEp: Double; var tokens: Double; var last: Double }
    var blocks: [Blk] = []; var cs: Double? = nil; var cf = 0.0; var ct = 0.0; var cl = 0.0
    for (ep, tot) in events {
        if cs == nil { cs = floorToHour(ep); cf = ep; ct = 0; cl = ep }
        else if ep - cl > FIVE || ep - cs! >= FIVE { blocks.append(Blk(start: cs!, firstEp: cf, tokens: ct, last: cl)); cs = floorToHour(ep); cf = ep; ct = 0 }
        ct += tot; cl = ep
    }
    if let s = cs { blocks.append(Blk(start: s, firstEp: cf, tokens: ct, last: cl)) }
    guard let blk = blocks.last else { return nil }
    let reset = blk.start + FIVE
    return ClaudeBlock(tokens: blk.tokens, reset: reset, firstEp: blk.firstEp, active: nowEpoch() < reset && (nowEpoch() - blk.last) < FIVE)
}
func claudeWeekTokens(_ events: [(Double, Double)]) -> Double { events.filter { $0.0 >= nowEpoch() - 7*86400 }.reduce(0) { $0 + $1.1 } }
// (current 5h-block tokens [0 if no active block], 7-day tokens) — used by calibration.
func claudeCalibrationSums() -> (five: Double, week: Double) {
    let ev = gatherClaudeEvents()
    let cb = currentClaudeBlock(ev)
    return ((cb?.active == true) ? cb!.tokens : 0, claudeWeekTokens(ev))
}

func readClaudeLocal() -> ProviderStatus {
    var st = ProviderStatus(key: "Cl", name: "Claude", available: false)
    let base = (HOME as NSString).appendingPathComponent(".claude/projects")
    guard FileManager.default.fileExists(atPath: base) else { st.problem = "not installed (~/.claude/projects absent)"; return st }
    let events = gatherClaudeEvents()
    guard !events.isEmpty else {
        st.available = true; st.plan = "est."
        st.fiveHour = WindowStat(remaining: 100, note: "idle"); st.weekly = WindowStat(remaining: 100, note: "idle")
        st.details = ["no activity in last 7d"]; return st
    }
    st.available = true; st.plan = "est."
    if let blk = currentClaudeBlock(events), blk.active {
        let b = Cfg.claude5hBudget
        st.fiveHour = WindowStat(remaining: max(0, min(100, Int((100 * (1 - blk.tokens / b)).rounded()))), resetEpoch: blk.reset, note: "\(tokLabel(blk.tokens)) tok")
        let elapsedMin = max(1, (nowEpoch() - blk.firstEp) / 60)   // burn from first real event, not floored hour
        let burn = blk.tokens / elapsedMin
        st.details.append("5h used \(tokLabel(blk.tokens)) / \(tokLabel(b)) est.")
        st.details.append("burn \(tokLabel(burn))/min · ~\(tokLabel(blk.tokens + burn * max(0, (blk.reset - nowEpoch()) / 60))) by reset")
    } else {
        st.fiveHour = WindowStat(remaining: 100, note: "idle")
    }
    let weekTokens = claudeWeekTokens(events)
    let wb = Cfg.claudeWeekBudget
    st.weekly = WindowStat(remaining: max(0, min(100, Int((100 * (1 - weekTokens / wb)).rounded()))), note: "\(tokLabel(weekTokens))/7d")
    st.details.append("7d used \(tokLabel(weekTokens)) / \(tokLabel(wb)) est. · calibrate in Settings")
    return st
}

// MARK: - Official web-API usage (exact %, method from github.com/f-is-h/usage4claude)
// Claude → claude.ai web session (sessionKey cookie). Codex → chatgpt.com session-token.

let WEB_UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

// Synchronous GET (runs on the background refresh queue, never main).
func httpGet(_ urlStr: String, headers: [String: String], timeout: TimeInterval = 12) -> (status: Int, body: Data)? {
    guard let url = URL(string: urlStr) else { return nil }
    var req = URLRequest(url: url, timeoutInterval: timeout)
    req.httpMethod = "GET"
    for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
    let cfg = URLSessionConfiguration.ephemeral
    cfg.httpShouldSetCookies = false            // send our explicit Cookie header verbatim
    cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
    let session = URLSession(configuration: cfg)
    defer { session.finishTasksAndInvalidate() }
    let sem = DispatchSemaphore(value: 0)
    var out: (Int, Data)? = nil
    let task = session.dataTask(with: req) { data, resp, _ in
        if let http = resp as? HTTPURLResponse { out = (http.statusCode, data ?? Data()) }
        sem.signal()
    }
    task.resume()
    if sem.wait(timeout: .now() + timeout + 2) == .timedOut { task.cancel() }
    return out
}

// ---- Claude (claude.ai) ----
struct ClaudeLimitWire: Codable { let utilization: Double; let resets_at: String? }
struct ClaudeUsageWire: Codable { let five_hour: ClaudeLimitWire?; let seven_day: ClaudeLimitWire?; let seven_day_opus: ClaudeLimitWire?; let seven_day_sonnet: ClaudeLimitWire? }
struct ClaudeOrgWire: Codable { let uuid: String; let name: String?; let capabilities: [String]? }

func claudeHeaders(_ key: String) -> [String: String] {
    ["accept": "*/*", "content-type": "application/json",
     "anthropic-client-platform": "web_claude_ai", "anthropic-client-version": "1.0.0",
     "user-agent": WEB_UA, "origin": "https://claude.ai", "referer": "https://claude.ai/settings/usage",
     "sec-fetch-dest": "empty", "sec-fetch-mode": "cors", "sec-fetch-site": "same-origin",
     "Cookie": "sessionKey=\(key)"]
}

func readClaudeOfficial() -> ProviderStatus {
    var st = ProviderStatus(key: "Cl", name: "Claude", available: false)
    let key = Cfg.claudeSessionKey
    let h = claudeHeaders(key)
    var org = Cfg.claudeOrgUuid
    if org.isEmpty {
        guard let r = httpGet("https://claude.ai/api/organizations", headers: h) else { st.problem = "network error"; return st }
        if r.status == 401 || r.status == 403 { st.problem = "login expired — update sessionKey"; return st }
        guard r.status == 200, let orgs = try? JSONDecoder().decode([ClaudeOrgWire].self, from: r.body), !orgs.isEmpty else {
            st.problem = "org lookup failed (HTTP \(r.status))"; return st
        }
        org = (orgs.first { ($0.capabilities ?? []).contains { $0.contains("claude") } } ?? orgs[0]).uuid
        Cfg.claudeOrgUuid = org
    }
    guard let r = httpGet("https://claude.ai/api/organizations/\(org)/usage", headers: h) else { st.problem = "network error"; return st }
    if r.status == 401 || r.status == 403 { Cfg.claudeOrgUuid = ""; st.problem = "login expired — update sessionKey"; return st }
    guard r.status == 200, let u = try? JSONDecoder().decode(ClaudeUsageWire.self, from: r.body) else {
        st.problem = "usage unavailable (HTTP \(r.status))"; return st
    }
    func win(_ w: ClaudeLimitWire?) -> WindowStat? {
        guard let w = w else { return nil }
        return WindowStat(remaining: max(0, min(100, Int((100 - w.utilization).rounded()))), resetEpoch: parseISO(w.resets_at ?? ""), refilled: false)
    }
    st.available = true; st.plan = "official"
    st.fiveHour = win(u.five_hour)
    st.weekly = win(u.seven_day)
    if let o = u.seven_day_opus, !(o.utilization == 0 && o.resets_at == nil) { st.details.append("Opus 7d: \(Int((100 - o.utilization).rounded()))% left") }
    if let s = u.seven_day_sonnet, !(s.utilization == 0 && s.resets_at == nil) { st.details.append("Sonnet 7d: \(Int((100 - s.utilization).rounded()))% left") }
    return st
}

// ---- Codex (chatgpt.com) ----
struct CodexWindowWire: Codable { let used_percent: Double; let limit_window_seconds: Int?; let reset_after_seconds: Int?; let reset_at: Int? }
struct CodexRateLimitWire: Codable { let primary_window: CodexWindowWire?; let secondary_window: CodexWindowWire?; let limit_reached: Bool? }
struct CodexUsageWire: Codable { let plan_type: String?; let rate_limit: CodexRateLimitWire? }
struct CodexSessionWire: Codable { let accessToken: String? }

// Codex CLI's own OAuth access token (~/.codex/auth.json) — lets official Codex work
// WITHOUT a separate ChatGPT browser login, since the user already authed the codex CLI.
func codexCLIAccessToken() -> String? {
    let p = (HOME as NSString).appendingPathComponent(".codex/auth.json")
    guard let data = FileManager.default.contents(atPath: p),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let tokens = obj["tokens"] as? [String: Any],
          let at = tokens["access_token"] as? String, !at.isEmpty else { return nil }
    return at
}

func readCodexOfficial() -> ProviderStatus {
    var st = ProviderStatus(key: "Cx", name: "Codex", available: false)
    // accessToken: prefer ChatGPT web session-token exchange; else reuse the codex CLI token.
    var access: String? = nil
    let tok = Cfg.codexSessionToken
    if !tok.isEmpty {
        let sh = ["accept": "*/*", "user-agent": WEB_UA, "origin": "https://chatgpt.com", "referer": "https://chatgpt.com/",
                  "sec-fetch-dest": "empty", "sec-fetch-mode": "cors", "sec-fetch-site": "same-origin",
                  "Cookie": "__Secure-next-auth.session-token=\(tok)"]
        if let sr = httpGet("https://chatgpt.com/api/auth/session", headers: sh), sr.status == 200,
           let sess = try? JSONDecoder().decode(CodexSessionWire.self, from: sr.body), let a = sess.accessToken, !a.isEmpty {
            access = a
        }
    }
    if access == nil { access = codexCLIAccessToken() }
    guard let accessToken = access, !accessToken.isEmpty else { st.problem = "no codex login"; return st }
    let uh = ["accept": "*/*", "content-type": "application/json", "user-agent": WEB_UA, "authorization": "Bearer \(accessToken)",
              "origin": "https://chatgpt.com", "referer": "https://chatgpt.com/",
              "sec-fetch-dest": "empty", "sec-fetch-mode": "cors", "sec-fetch-site": "same-origin"]
    guard let ur = httpGet("https://chatgpt.com/backend-api/wham/usage", headers: uh), ur.status == 200,
          let u = try? JSONDecoder().decode(CodexUsageWire.self, from: ur.body) else { st.problem = "usage unavailable"; return st }
    func win(_ w: CodexWindowWire?) -> WindowStat? {
        guard let w = w else { return nil }
        let reset = w.reset_at.map { Double($0) }
        let refilled = (reset ?? .greatestFiniteMagnitude) <= nowEpoch()
        return WindowStat(remaining: refilled ? 100 : max(0, min(100, Int((100 - w.used_percent).rounded()))), resetEpoch: reset, refilled: refilled)
    }
    st.available = true; st.plan = u.plan_type ?? "official"
    st.fiveHour = win(u.rate_limit?.primary_window)
    st.weekly = win(u.rate_limit?.secondary_window)
    st.throttled = (u.rate_limit?.limit_reached == true) && !(st.fiveHour?.refilled ?? false)
    return st
}

// ---- dispatchers: official (if a token is set) first, else local ----
func readClaude() -> ProviderStatus {
    guard !Cfg.claudeSessionKey.isEmpty else { return readClaudeLocal() }
    let off = readClaudeOfficial()
    if off.available { return off }
    var local = readClaudeLocal()
    local.details.insert("⚠︎ official login: \(off.problem ?? "failed") — showing estimate", at: 0)
    return local
}
func readCodex() -> ProviderStatus {
    guard !Cfg.codexSessionToken.isEmpty || codexCLIAccessToken() != nil else { return readCodexLocal() }
    let off = readCodexOfficial()
    if off.available { return off }
    var local = readCodexLocal()   // disk rate_limits are also official, just updated only when codex runs
    local.details.insert("⚠︎ live: \(off.problem ?? "failed") — showing last disk snapshot", at: 0)
    return local
}

// MARK: - Gemini (best-effort status)

func readGemini() -> ProviderStatus {
    var st = ProviderStatus(key: "Gm", name: "Gemini", available: false)
    let gdir = (HOME as NSString).appendingPathComponent(".gemini")
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: gdir, isDirectory: &isDir), isDir.boolValue else { st.problem = "not installed (~/.gemini absent)"; return st }
    let creds = (gdir as NSString).appendingPathComponent("oauth_creds.json")
    if FileManager.default.fileExists(atPath: creds) {
        st.available = true
        var who = "logged in"
        let acct = (gdir as NSString).appendingPathComponent("google_accounts.json")
        if let data = FileManager.default.contents(atPath: acct),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let active = obj["active"] as? String { who = active }
        st.plan = who
        st.details = ["no local quota API — % unavailable", "free OAuth tier ~1000 req/day (not tracked locally)"]
    } else {
        st.problem = "installed, not logged in"
    }
    return st
}

