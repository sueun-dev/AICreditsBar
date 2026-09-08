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
        let reset = sanitizeEpoch((w["resets_at"] as? NSNumber)?.doubleValue)
        // Scale staleness to the window length: a 90-min-old weekly snapshot is still fine,
        // a 90-min-old 5h snapshot is not. (5h → ~90 min, weekly → ~50 h.)
        let windowMin = (w["window_minutes"] as? NSNumber)?.doubleValue ?? 300
        let aged = (age ?? 0) > max(CODEX_STALE, windowMin * 60 * 0.3)
        // Don't trust an inferred refill from an aged snapshot (the new window may already be in use).
        let resetPassed = reset.map { $0 <= nowEpoch() } ?? false
        return WindowStat(remaining: used.isFinite ? pctClamp(100 - used) : nil,
                          resetEpoch: reset, stale: aged || resetPassed)
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
    func retain(paths: Set<String>) {
        lock.lock(); defer { lock.unlock() }; cache = cache.filter { paths.contains($0.key) }
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
        guard tot.isFinite, tot >= 0 else { continue }
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
    claudeCache.retain(paths: Set(files.map { $0.path }))
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
    st.source = .estimate
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
        st.fiveHour = WindowStat(remaining: pctClamp(100 * (1 - blk.tokens / b)), resetEpoch: blk.reset, note: "\(tokLabel(blk.tokens)) tok")
        let elapsedMin = max(1, (nowEpoch() - blk.firstEp) / 60)   // burn from first real event, not floored hour
        let burn = blk.tokens / elapsedMin
        st.details.append("5h used \(tokLabel(blk.tokens)) / \(tokLabel(b)) est.")
        st.details.append("burn \(tokLabel(burn))/min · ~\(tokLabel(blk.tokens + burn * max(0, (blk.reset - nowEpoch()) / 60))) by reset")
    } else {
        st.fiveHour = WindowStat(remaining: 100, note: "idle")
    }
    let weekTokens = claudeWeekTokens(events)
    let wb = Cfg.claudeWeekBudget
    st.weekly = WindowStat(remaining: pctClamp(100 * (1 - weekTokens / wb)), note: "\(tokLabel(weekTokens))/7d")
    st.details.append("7d used \(tokLabel(weekTokens)) / \(tokLabel(wb)) est. · calibrate: --set-week-used <%>")
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
    let result = HTTPResult()
    let task = session.dataTask(with: req) { data, resp, _ in
        if let http = resp as? HTTPURLResponse { result.store((http.statusCode, data ?? Data())) }
        sem.signal()
    }
    task.resume()
    if sem.wait(timeout: .now() + timeout + 2) == .timedOut { task.cancel(); return nil }
    return result.load()
}

private final class HTTPResult {
    private let lock = NSLock()
    private var value: (Int, Data)?
    func store(_ value: (Int, Data)) { lock.lock(); defer { lock.unlock() }; self.value = value }
    func load() -> (Int, Data)? { lock.lock(); defer { lock.unlock() }; return value }
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
    let h = claudeHeaders(Cfg.claudeSessionKey)
    func detectOrg() -> String? {
        guard let r = httpGet("https://claude.ai/api/organizations", headers: h) else { st.problem = "network error"; return nil }
        if r.status == 401 || r.status == 403 { st.problem = "login expired — update sessionKey"; return nil }
        guard r.status == 200, let orgs = try? JSONDecoder().decode([ClaudeOrgWire].self, from: r.body), !orgs.isEmpty else {
            st.problem = "org lookup failed (HTTP \(r.status))"; return nil
        }
        let pref = ["claude_pro", "claude_max", "claude_team", "chat", "raven"]   // consumer-subscription markers
        let chosen = orgs.first { o in (o.capabilities ?? []).contains { c in pref.contains { c.contains($0) } } }
            ?? orgs.first { ($0.capabilities ?? []).contains { $0.contains("claude") } } ?? orgs[0]
        return chosen.uuid
    }
    func fetchUsage(_ org: String) -> ClaudeUsageWire? {
        guard let r = httpGet("https://claude.ai/api/organizations/\(org)/usage", headers: h) else { st.problem = "network error"; return nil }
        if r.status == 401 || r.status == 403 || r.status == 404 { Cfg.claudeOrgUuid = ""; st.problem = "login expired — update sessionKey"; return nil }
        guard r.status == 200, let u = try? JSONDecoder().decode(ClaudeUsageWire.self, from: r.body) else {
            st.problem = "usage unavailable (HTTP \(r.status))"; return nil   // Cloudflare HTML / non-JSON lands here too
        }
        return u
    }
    func win(_ w: ClaudeLimitWire?) -> WindowStat? {
        guard let w = w else { return nil }
        guard w.utilization.isFinite else { return nil }
        return WindowStat(remaining: pctClamp(100 - w.utilization), resetEpoch: sanitizeEpoch(parseISO(w.resets_at ?? "")))
    }
    func hasWindow(_ u: ClaudeUsageWire) -> Bool { u.five_hour != nil || u.seven_day != nil || u.seven_day_opus != nil || u.seven_day_sonnet != nil }

    var org = Cfg.claudeOrgUuid
    let fromCache = !org.isEmpty
    if org.isEmpty { guard let o = detectOrg() else { return st }; org = o }
    guard var u = fetchUsage(org) else { return st }
    // A cached org that yields no windows may be the wrong/stale org — re-detect once.
    if !hasWindow(u) && fromCache {
        Cfg.claudeOrgUuid = ""
        if let o = detectOrg(), let u2 = fetchUsage(o) { org = o; u = u2 }
    }
    st.fiveHour = win(u.five_hour); st.weekly = win(u.seven_day)
    st.available = (st.fiveHour != nil || st.weekly != nil)
    guard st.available else { st.problem = "usage payload empty/changed (HTTP 200)"; return st }
    st.plan = "official"
    Cfg.claudeOrgUuid = org   // cache only after confirming this org has usable windows
    if let o = u.seven_day_opus, !(o.utilization == 0 && o.resets_at == nil) { st.details.append("Opus 7d: \(pctClamp(100 - o.utilization))% left") }
    if let s = u.seven_day_sonnet, !(s.utilization == 0 && s.resets_at == nil) { st.details.append("Sonnet 7d: \(pctClamp(100 - s.utilization))% left") }
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
        // Accept either an absolute reset_at or a relative reset_after_seconds.
        guard w.used_percent.isFinite else { return nil }
        let reset = sanitizeEpoch(w.reset_at.map { Double($0) } ?? w.reset_after_seconds.map { nowEpoch() + Double($0) })
        return WindowStat(remaining: pctClamp(100 - w.used_percent), resetEpoch: reset,
                          stale: reset.map { $0 <= nowEpoch() } ?? false)
    }
    st.fiveHour = win(u.rate_limit?.primary_window)
    st.weekly = win(u.rate_limit?.secondary_window)
    st.available = (st.fiveHour != nil || st.weekly != nil)   // a hollow 200 must not be cached as good
    guard st.available else { st.problem = "usage payload empty/changed (HTTP 200)"; return st }
    st.plan = u.plan_type ?? "official"
    st.throttled = (u.rate_limit?.limit_reached == true) && !(st.fiveHour?.refilled ?? false)
    return st
}

// ---- official result cache (stops the bar flapping between official ⇄ estimate on a
//      transient network hiccup, and avoids hammering the web APIs on every 30s tick).
let OFFICIAL_TTL: Double = 30          // poll APIs at most twice per minute automatically
let OFFICIAL_MAX_AGE: Double = 30 * 60 // keep showing the last good official up to here when refresh fails
struct CachedOfficial { var status: ProviderStatus; var at: Double }
var officialCache: [String: CachedOfficial] = [:]
private var officialFailures: [String: (retryAt: Double, count: Int, problem: String)] = [:]
private var officialGeneration: [String: UInt64] = [:]
let officialLock = NSLock()
func cachedOfficial(_ k: String) -> CachedOfficial? { officialLock.lock(); defer { officialLock.unlock() }; return officialCache[k] }
func storeOfficial(_ k: String, _ s: ProviderStatus) { officialLock.lock(); defer { officialLock.unlock() }; officialCache[k] = CachedOfficial(status: s, at: nowEpoch()) }
func clearOfficial(_ k: String) {
    officialLock.lock(); defer { officialLock.unlock() }
    officialCache[k] = nil; officialFailures[k] = nil
    officialGeneration[k, default: 0] &+= 1
}

private func fetchWithBackoff(_ key: String, force: Bool, fetch: () -> ProviderStatus) -> ProviderStatus {
    officialLock.lock(); let failure = officialFailures[key]; let generation = officialGeneration[key, default: 0]; officialLock.unlock()
    if !force, let failure = failure, failure.retryAt > nowEpoch() {
        return ProviderStatus(key: key, name: key, available: false, problem: failure.problem)
    }
    let status = fetch()
    officialLock.lock(); defer { officialLock.unlock() }
    guard generation == officialGeneration[key, default: 0] else { return status }
    if status.available { officialFailures[key] = nil }
    else {
        let count = min(4, (failure?.count ?? 0) + 1)
        officialFailures[key] = (nowEpoch() + min(300, OFFICIAL_TTL * pow(2, Double(count - 1))), count, status.problem ?? "unavailable")
    }
    return status
}

// Try official; on failure prefer the last good official over a divergent fallback. `fetch`
// returns a ProviderStatus whose `.available` indicates success; `fallback` is the local reader.
func officialOrCached(_ key: String, force: Bool = false, fetch: () -> ProviderStatus, fallback: () -> ProviderStatus, fallbackNote: (String) -> String) -> ProviderStatus {
    officialLock.lock()
    let hasFailure = officialFailures[key] != nil
    let generation = officialGeneration[key, default: 0]
    officialLock.unlock()
    if !force, !hasFailure, let c = cachedOfficial(key), nowEpoch() - c.at < OFFICIAL_TTL {
        return c.status.aged(by: max(0, nowEpoch() - c.at))
    }
    var off = fetchWithBackoff(key, force: force, fetch: fetch)
    if off.available {
        off.source = .official; off.snapshotAge = 0
        off = off.aged(by: 0)
        officialLock.lock()
        if generation == officialGeneration[key, default: 0] { officialCache[key] = CachedOfficial(status: off, at: nowEpoch()) }
        officialLock.unlock()
        return off
    }
    if let c = cachedOfficial(key), nowEpoch() - c.at < OFFICIAL_MAX_AGE {                 // transient fail: hold last good
        let age = nowEpoch() - c.at
        func held(_ w: WindowStat?) -> WindowStat? {           // re-derive time-dependent fields, flag as stale
            guard var w = w else { return nil }
            w.refilled = false
            w.stale = true; return w
        }
        var s = c.status; s.fiveHour = held(s.fiveHour); s.weekly = held(s.weekly); s.snapshotAge = age
        s.details.append("↻ refresh failed (\(off.problem ?? "")) — last good \(ageLabel(age))")
        return s
    }
    var local = fallback(); local.details.insert(fallbackNote(off.problem ?? "failed"), at: 0); return local
}

// ---- dispatchers: official (if a token is set) first, else local ----
func readClaude(force: Bool = false) -> ProviderStatus {
    guard !Cfg.claudeSessionKey.isEmpty else { clearOfficial("Cl"); return readClaudeLocal() }
    return officialOrCached("Cl", force: force, fetch: readClaudeOfficial, fallback: readClaudeLocal,
                            fallbackNote: { "⚠︎ official login: \($0) — showing estimate" })
}
func readCodex(force: Bool = false) -> ProviderStatus {
    guard !Cfg.codexSessionToken.isEmpty || codexCLIAccessToken() != nil else { clearOfficial("Cx"); return readCodexLocal() }
    return officialOrCached("Cx", force: force, fetch: readCodexOfficial, fallback: readCodexLocal,
                            fallbackNote: { "⚠︎ live: \($0) — showing last disk snapshot" })
}

// MARK: - Gemini (best-effort status)

func readGemini() -> ProviderStatus {
    var st = ProviderStatus(key: "Gm", name: "Gemini", available: false)
    st.source = .statusOnly
    let gdir = (HOME as NSString).appendingPathComponent(".gemini")
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: gdir, isDirectory: &isDir), isDir.boolValue else { st.problem = "not installed (~/.gemini absent)"; return st }
    let creds = (gdir as NSString).appendingPathComponent("oauth_creds.json")
    if FileManager.default.fileExists(atPath: creds) {
        st.available = true
        var who = "local login found"
        let acct = (gdir as NSString).appendingPathComponent("google_accounts.json")
        if let data = FileManager.default.contents(atPath: acct),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let active = obj["active"] as? String { who = active }
        st.plan = who
        st.details = ["Local login file found · quota and session validity are not verified"]
    } else {
        st.problem = "installed, not logged in"
    }
    return st
}
