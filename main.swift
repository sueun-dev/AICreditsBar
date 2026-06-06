// AICreditsBar — macOS menu-bar app: remaining token/quota for Codex, Claude, Gemini.
// Single-file AppKit app, compiled with swiftc. See build.sh.
//   Codex  = exact official % (5h + weekly) from ~/.codex/sessions rate_limits.
//   Claude = token estimate vs a configurable budget (5h block + 7-day) — ccusage-style.
//   Gemini = installed/login status (no local quota API exists).
// Auto-detects which CLIs you use by reading their local data dirs. No network calls.
import AppKit
import Foundation

// MARK: - Config (UserDefaults-backed, with defaults)

enum Cfg {
    static let d = UserDefaults.standard
    static func dbl(_ k: String, _ def: Double) -> Double { d.object(forKey: k) == nil ? def : d.double(forKey: k) }
    static func int(_ k: String, _ def: Int) -> Int { d.object(forKey: k) == nil ? def : d.integer(forKey: k) }
    static func bool(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) == nil ? def : d.bool(forKey: k) }
    static func color(_ k: String, _ def: NSColor) -> NSColor {
        if let s = d.string(forKey: k), let c = NSColor(hex: s) { return c }; return def
    }
    static func validBudget(_ v: Double, _ def: Double) -> Double { (v.isFinite && v >= 1 && v <= 1e15) ? v : def }

    static var displayMode: String { get { d.string(forKey: "displayMode") ?? "5h" } set { d.set(newValue, forKey: "displayMode") } }   // 5h | week | both | min
    static var showCodex: Bool  { get { bool("showCodex", true) }  set { d.set(newValue, forKey: "showCodex") } }
    static var showClaude: Bool { get { bool("showClaude", true) } set { d.set(newValue, forKey: "showClaude") } }
    static var showGemini: Bool { get { bool("showGemini", true) } set { d.set(newValue, forKey: "showGemini") } }
    static var showLabels: Bool { get { bool("showLabels", true) } set { d.set(newValue, forKey: "showLabels") } }
    static var refreshInterval: Double { get { min(3600, max(5, dbl("refreshInterval", 30))) } set { d.set(newValue, forKey: "refreshInterval") } }
    static var greenAbove: Int { get { int("greenAbove", 50) } set { d.set(newValue, forKey: "greenAbove") } }
    static var yellowAbove: Int { get { int("yellowAbove", 20) } set { d.set(newValue, forKey: "yellowAbove") } }
    static var colorHigh: NSColor { get { color("colorHigh", .systemGreen) }  set { d.set(newValue.hexString, forKey: "colorHigh") } }
    static var colorMid: NSColor  { get { color("colorMid", .systemYellow) }  set { d.set(newValue.hexString, forKey: "colorMid") } }
    static var colorLow: NSColor  { get { color("colorLow", .systemRed) }     set { d.set(newValue.hexString, forKey: "colorLow") } }
    static var colorUnknown: NSColor { get { color("colorUnknown", .secondaryLabelColor) } set { d.set(newValue.hexString, forKey: "colorUnknown") } }
    static var claude5hBudget: Double { get { validBudget(dbl("claude5hBudget", 220_000_000), 220_000_000) } set { d.set(newValue, forKey: "claude5hBudget") } }
    static var claudeWeekBudget: Double { get { validBudget(dbl("claudeWeekBudget", 1_500_000_000), 1_500_000_000) } set { d.set(newValue, forKey: "claudeWeekBudget") } }
    static var claudePlan: String { get { d.string(forKey: "claudePlan") ?? "Max 20x" } set { d.set(newValue, forKey: "claudePlan") } }

    static let planBudgets: [String: Double] = ["Pro": 19_000_000, "Max 5x": 88_000_000, "Max 20x": 220_000_000]

    static func resetAll() {
        for k in ["displayMode","showCodex","showClaude","showGemini","showLabels","refreshInterval",
                  "greenAbove","yellowAbove","colorHigh","colorMid","colorLow","colorUnknown",
                  "claude5hBudget","claudeWeekBudget","claudePlan"] { d.removeObject(forKey: k) }
    }
}

extension NSColor {
    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02X%02X%02X", Int(round(c.redComponent*255)), Int(round(c.greenComponent*255)), Int(round(c.blueComponent*255)))
    }
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces); if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = Int(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v>>16)&0xFF)/255, green: CGFloat((v>>8)&0xFF)/255, blue: CGFloat(v&0xFF)/255, alpha: 1)
    }
}

// MARK: - Model

struct WindowStat {
    var remaining: Int?        // percent remaining (0-100), nil = unknown
    var resetEpoch: Double?    // unix seconds when window resets
    var refilled: Bool = false // window's scheduled reset has passed -> fresh quota
    var stale: Bool = false    // snapshot too old to trust (window not yet reset)
    var note: String?
}

struct ProviderStatus {
    var key: String
    var name: String
    var available: Bool
    var fiveHour: WindowStat?
    var weekly: WindowStat?
    var plan: String?
    var snapshotAge: Double?
    var throttled: Bool = false
    var details: [String] = []
    var problem: String?
}

// MARK: - Helpers

let HOME = FileManager.default.homeDirectoryForCurrentUser.path
func nowEpoch() -> Double { Date().timeIntervalSince1970 }
func floorToHour(_ ep: Double) -> Double { ep - ep.truncatingRemainder(dividingBy: 3600) }

func resetLabel(_ ts: Double?) -> String {
    guard let ts = ts else { return "?" }
    let dd = ts - nowEpoch()
    if dd <= 0 { return "now" }
    if dd < 3600 { return "in \(Int((dd/60).rounded()))m" }
    if dd < 86400 { let h = Int(dd/3600); let m = Int((dd - Double(h)*3600)/60); return "in \(h)h \(m)m" }
    let days = Int(dd/86400); let h = Int((dd - Double(days)*86400)/3600); return "in \(days)d \(h)h"
}
func ageLabel(_ secs: Double?) -> String {
    guard let s = secs, s >= 0 else { return "?" }
    if s < 90 { return "just now" }
    if s < 3600 { return "\(Int(s/60))m ago" }
    if s < 86400 { return String(format: "%.1fh ago", s/3600) }
    return String(format: "%.1fd ago", s/86400)
}
func tokLabel(_ t: Double) -> String {
    if t >= 1_000_000 { return String(format: "%.1fM", t/1_000_000) }
    if t >= 1_000 { return String(format: "%.0fK", t/1000) }
    return String(format: "%.0f", t)
}

// Whole-file matching lines.
func grepLines(_ path: String, must: String, sizeCap: Int = 400_000_000) -> [String] {
    let fm = FileManager.default
    if let attrs = try? fm.attributesOfItem(atPath: path),
       let size = (attrs[.size] as? NSNumber)?.intValue, size > sizeCap { return [] }
    guard let data = fm.contents(atPath: path), let text = String(data: data, encoding: .utf8) else { return [] }
    var out: [String] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) where must.isEmpty || line.contains(must) {
        out.append(String(line))
    }
    return out
}
// Like grepLines but, for files bigger than maxBytes, reads only the LAST maxBytes.
// Append-only logs (Codex rollouts) keep the freshest record at EOF, so the tail suffices.
func tailLines(_ path: String, must: String, maxBytes: Int = 2_000_000) -> [String] {
    let fm = FileManager.default
    guard let attrs = try? fm.attributesOfItem(atPath: path),
          let size = (attrs[.size] as? NSNumber)?.intValue else { return [] }
    if size <= maxBytes { return grepLines(path, must: must) }
    guard let fh = FileHandle(forReadingAtPath: path) else { return [] }
    defer { try? fh.close() }
    do {
        try fh.seek(toOffset: UInt64(size - maxBytes))
        let data = fh.readDataToEndOfFile()
        var text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        if let nl = text.firstIndex(of: "\n") { text = String(text[text.index(after: nl)...]) } // drop partial first line
        var out: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) where must.isEmpty || line.contains(must) {
            out.append(String(line))
        }
        return out
    } catch { return [] }
}
func parseISO(_ s: String) -> Double? {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let dte = f.date(from: s) { return dte.timeIntervalSince1970 }
    f.formatOptions = [.withInternetDateTime]
    if let dte = f.date(from: s) { return dte.timeIntervalSince1970 }
    return nil
}
func filesByMtime(under dir: String, suffix: String, newerThan: Double? = nil) -> [(path: String, mtime: Double, size: Int)] {
    let fm = FileManager.default
    guard let en = fm.enumerator(atPath: dir) else { return [] }
    var result: [(String, Double, Int)] = []
    for case let rel as String in en where rel.hasSuffix(suffix) {
        let full = (dir as NSString).appendingPathComponent(rel)
        guard let attrs = try? fm.attributesOfItem(atPath: full),
              let mt = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 else { continue }
        if let nt = newerThan, mt < nt { continue }
        let sz = (attrs[.size] as? NSNumber)?.intValue ?? 0
        result.append((full, mt, sz))
    }
    return result.sorted { $0.1 > $1.1 }.map { (path: $0.0, mtime: $0.1, size: $0.2) }
}
func digRateLimits(_ obj: Any) -> [String: Any]? {
    if let dd = obj as? [String: Any] {
        if let p = dd["primary"] as? [String: Any], p["used_percent"] != nil { return dd }
        for (_, v) in dd { if let r = digRateLimits(v) { return r } }
    } else if let arr = obj as? [Any] {
        for v in arr { if let r = digRateLimits(v) { return r } }
    }
    return nil
}

// MARK: - Codex (exact official %)

let CODEX_STALE: Double = 90 * 60   // snapshot older than this (window not yet reset) -> show as stale

func readCodex() -> ProviderStatus {
    var st = ProviderStatus(key: "Cx", name: "Codex", available: false)
    let base = (HOME as NSString).appendingPathComponent(".codex/sessions")
    guard FileManager.default.fileExists(atPath: base) else { st.problem = "not installed (~/.codex/sessions absent)"; return st }
    let files = Array(filesByMtime(under: base, suffix: ".jsonl").prefix(20))
    var bestEpoch = -1.0
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
    for line in grepLines(path, must: "\"usage\"") {
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

func readClaude() -> ProviderStatus {
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

// MARK: - Rendering

func colorFor(_ w: WindowStat?) -> NSColor {
    guard let w = w else { return Cfg.colorUnknown }
    if w.stale { return Cfg.colorUnknown }
    if w.refilled { return Cfg.colorHigh }
    guard let r = w.remaining else { return Cfg.colorUnknown }
    if r > Cfg.greenAbove { return Cfg.colorHigh }
    if r >= Cfg.yellowAbove { return Cfg.colorMid }
    return Cfg.colorLow
}
func windowText(_ w: WindowStat?) -> String {
    guard let w = w else { return "?" }
    if w.refilled { return "↑" }
    if let r = w.remaining { return "\(r)%" }
    return "?"
}
func barInfo(_ p: ProviderStatus) -> (String, NSColor) {
    guard p.available else { return ("—", Cfg.colorUnknown) }
    let f = p.fiveHour, w = p.weekly
    switch Cfg.displayMode {
    case "week":
        if w != nil { return (windowText(w), colorFor(w)) }
        return (windowText(f), colorFor(f))
    case "both":
        if w != nil {
            let worse = (f?.remaining ?? 101) <= (w?.remaining ?? 101) ? f : w
            return ("\(windowText(f))/\(windowText(w))", colorFor(worse))
        }
        return (windowText(f), colorFor(f))
    case "min":
        let cands = [f, w].compactMap { $0 }
        let worst = cands.min { ($0.remaining ?? 101) < ($1.remaining ?? 101) } ?? f
        return (windowText(worst), colorFor(worst))
    default:
        if f == nil && w != nil { return (windowText(w), colorFor(w)) }
        return (windowText(f), colorFor(f))
    }
}
func barSegment(_ p: ProviderStatus) -> NSAttributedString {
    let mono = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    let s = NSMutableAttributedString()
    if Cfg.showLabels { s.append(NSAttributedString(string: "\(p.key) ", attributes: [.font: mono, .foregroundColor: NSColor.labelColor])) }
    let (txt, col) = barInfo(p)
    s.append(NSAttributedString(string: txt, attributes: [.font: mono, .foregroundColor: col]))
    return s
}

// MARK: - Settings window

final class SettingsWindow: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    var window: NSWindow?
    var onChange: () -> Void = {}

    let modePopup = NSPopUpButton(); let planPopup = NSPopUpButton()
    let cCodex = NSButton(checkboxWithTitle: "Codex", target: nil, action: nil)
    let cClaude = NSButton(checkboxWithTitle: "Claude", target: nil, action: nil)
    let cGemini = NSButton(checkboxWithTitle: "Gemini", target: nil, action: nil)
    let cLabels = NSButton(checkboxWithTitle: "Show provider labels (Cx/Cl/Gm)", target: nil, action: nil)
    let fRefresh = NSTextField(); let fGreen = NSTextField(); let fYellow = NSTextField()
    let f5hBudget = NSTextField(); let fWkBudget = NSTextField()
    let fReal5h = NSTextField(); let fRealWk = NSTextField()
    let calStatus = NSTextField(labelWithString: "")
    let wHigh = NSColorWell(); let wMid = NSColorWell(); let wLow = NSColorWell(); let wUnknown = NSColorWell()

    func show() {
        if window == nil { build() }
        load()
        NSApp.activate(ignoringOtherApps: true)
        window?.center(); window?.makeKeyAndOrderFront(nil)
    }
    private func row(_ label: String, _ control: NSView) -> NSStackView {
        let l = NSTextField(labelWithString: label); l.alignment = .right
        l.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let h = NSStackView(views: [l, control]); h.orientation = .horizontal; h.spacing = 10; h.alignment = .centerY
        return h
    }
    private func num(_ f: NSTextField, _ w: CGFloat = 90) { f.delegate = self; f.target = self; f.action = #selector(changed(_:)); f.widthAnchor.constraint(equalToConstant: w).isActive = true }
    private func well(_ w: NSColorWell) { w.target = self; w.action = #selector(colorChanged(_:)); w.widthAnchor.constraint(equalToConstant: 44).isActive = true; w.heightAnchor.constraint(equalToConstant: 24).isActive = true }

    func build() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 660), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "AICreditsBar — Settings"; win.delegate = self; win.isReleasedWhenClosed = false
        modePopup.addItems(withTitles: ["5-hour window", "Weekly window", "Both (5h/week)", "Lowest"]); modePopup.target = self; modePopup.action = #selector(changed(_:))
        planPopup.addItems(withTitles: ["Pro", "Max 5x", "Max 20x", "Custom"]); planPopup.target = self; planPopup.action = #selector(changed(_:))
        for b in [cCodex, cClaude, cGemini, cLabels] { b.target = self; b.action = #selector(changed(_:)) }
        for f in [fRefresh, fGreen, fYellow, f5hBudget, fWkBudget] { num(f) }
        for f in [fReal5h, fRealWk] { f.target = self; f.action = #selector(calibrate); f.widthAnchor.constraint(equalToConstant: 60).isActive = true }
        calStatus.font = .systemFont(ofSize: 11); calStatus.textColor = .secondaryLabelColor
        for w in [wHigh, wMid, wLow, wUnknown] { well(w) }
        func head(_ t: String) -> NSTextField { let l = NSTextField(labelWithString: t); l.font = .boldSystemFont(ofSize: 13); return l }
        let providers = NSStackView(views: [cCodex, cClaude, cGemini]); providers.orientation = .horizontal; providers.spacing = 14
        let thresholds = NSStackView(views: [NSTextField(labelWithString: "green >"), fGreen, NSTextField(labelWithString: "  yellow ≥"), fYellow, NSTextField(labelWithString: "% (else red)")])
        thresholds.orientation = .horizontal; thresholds.spacing = 6; thresholds.alignment = .centerY
        let colors = NSStackView(views: [NSTextField(labelWithString: "High"), wHigh, NSTextField(labelWithString: "Mid"), wMid, NSTextField(labelWithString: "Low"), wLow, NSTextField(labelWithString: "Unk"), wUnknown])
        colors.orientation = .horizontal; colors.spacing = 6; colors.alignment = .centerY
        let resetBtn = NSButton(title: "Reset to defaults", target: self, action: #selector(resetDefaults))
        let doneBtn = NSButton(title: "Done", target: self, action: #selector(closeWindow)); doneBtn.keyEquivalent = "\r"
        let footer = NSStackView(views: [resetBtn, NSView(), doneBtn]); footer.orientation = .horizontal; footer.distribution = .fill
        let note = NSTextField(labelWithString: "Claude has no official % on disk; calibrate it from /usage for accuracy."); note.textColor = .secondaryLabelColor; note.font = .systemFont(ofSize: 11)
        let calBtn = NSButton(title: "Calibrate", target: self, action: #selector(calibrate))
        let calRow = NSStackView(views: [NSTextField(labelWithString: "real 5h used"), fReal5h, NSTextField(labelWithString: "%  weekly"), fRealWk, NSTextField(labelWithString: "%"), calBtn])
        calRow.orientation = .horizontal; calRow.spacing = 6; calRow.alignment = .centerY
        let calHelp = NSTextField(labelWithString: "Run /usage in Claude Code, type the two numbers here, click Calibrate."); calHelp.textColor = .secondaryLabelColor; calHelp.font = .systemFont(ofSize: 11)
        let rows: [NSView] = [head("Display"), row("Show in menu bar:", modePopup), row("Providers:", providers), row("", cLabels), row("Refresh every (s):", fRefresh),
                              head("Colors & thresholds"), row("Thresholds:", thresholds), row("Colors:", colors),
                              head("Claude budget (estimate)"), row("Plan:", planPopup), row("5h budget (M tok):", f5hBudget), row("Weekly budget (M tok):", fWkBudget),
                              row("Calibrate:", calRow), calHelp, row("", calStatus), note, footer]
        let v = NSStackView(views: rows); v.orientation = .vertical; v.alignment = .leading; v.spacing = 10
        v.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18); v.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView(); content.addSubview(v); win.contentView = content
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: content.leadingAnchor), v.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            v.topAnchor.constraint(equalTo: content.topAnchor), v.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            footer.widthAnchor.constraint(equalTo: v.widthAnchor, constant: -36)])
        window = win
    }
    func load() {
        let modes = ["5h": 0, "week": 1, "both": 2, "min": 3]
        modePopup.selectItem(at: modes[Cfg.displayMode] ?? 0)
        cCodex.state = Cfg.showCodex ? .on : .off; cClaude.state = Cfg.showClaude ? .on : .off
        cGemini.state = Cfg.showGemini ? .on : .off; cLabels.state = Cfg.showLabels ? .on : .off
        fRefresh.stringValue = String(Int(Cfg.refreshInterval)); fGreen.stringValue = String(Cfg.greenAbove); fYellow.stringValue = String(Cfg.yellowAbove)
        f5hBudget.stringValue = String(format: "%g", Cfg.claude5hBudget/1_000_000); fWkBudget.stringValue = String(format: "%g", Cfg.claudeWeekBudget/1_000_000)
        planPopup.selectItem(withTitle: Cfg.planBudgets[Cfg.claudePlan] != nil ? Cfg.claudePlan : "Custom")
        wHigh.color = Cfg.colorHigh; wMid.color = Cfg.colorMid; wLow.color = Cfg.colorLow; wUnknown.color = Cfg.colorUnknown
        f5hBudget.isEnabled = (planPopup.titleOfSelectedItem == "Custom")
    }
    @objc func changed(_ sender: Any?) {
        let modes = ["5h", "week", "both", "min"]
        Cfg.displayMode = modes[max(0, modePopup.indexOfSelectedItem)]
        Cfg.showCodex = cCodex.state == .on; Cfg.showClaude = cClaude.state == .on; Cfg.showGemini = cGemini.state == .on; Cfg.showLabels = cLabels.state == .on
        if let r = Double(fRefresh.stringValue) { Cfg.refreshInterval = r }
        if let g = Int(fGreen.stringValue) { Cfg.greenAbove = max(0, min(100, g)) }
        if let y = Int(fYellow.stringValue) { Cfg.yellowAbove = max(0, min(100, y)) }
        if let plan = planPopup.titleOfSelectedItem {
            Cfg.claudePlan = plan
            if let b = Cfg.planBudgets[plan] { Cfg.claude5hBudget = b }
            else if let m = Double(f5hBudget.stringValue), m > 0 { Cfg.claude5hBudget = m * 1_000_000 }
        }
        if let m = Double(fWkBudget.stringValue), m > 0 { Cfg.claudeWeekBudget = m * 1_000_000 }
        load(); onChange()
    }
    // Save ONLY the well the user actually changed, so untouched colors keep their
    // dynamic (dark/light-aware) defaults instead of being frozen to a static hex.
    @objc func colorChanged(_ sender: NSColorWell) {
        if sender === wHigh { Cfg.colorHigh = sender.color }
        else if sender === wMid { Cfg.colorMid = sender.color }
        else if sender === wLow { Cfg.colorLow = sender.color }
        else if sender === wUnknown { Cfg.colorUnknown = sender.color }
        onChange()
    }
    func controlTextDidEndEditing(_ obj: Notification) { changed(nil) }
    // Derive Claude budgets from the user's real % (read from `/usage`) and the current token sums,
    // so the displayed % matches reality at the calibration point and tracks proportionally after.
    @objc func calibrate() {
        let sums = claudeCalibrationSums()
        var done: [String] = []
        if let p = Double(fReal5h.stringValue), p > 0, p <= 100, sums.five > 0 {
            Cfg.claudePlan = "Custom"; Cfg.claude5hBudget = sums.five / (p / 100); done.append("5h≈\(tokLabel(Cfg.claude5hBudget))")
        }
        if let p = Double(fRealWk.stringValue), p > 0, p <= 100, sums.week > 0 {
            Cfg.claudeWeekBudget = sums.week / (p / 100); done.append("wk≈\(tokLabel(Cfg.claudeWeekBudget))")
        }
        calStatus.stringValue = done.isEmpty ? "Enter a non-zero % (and use Claude first so there are tokens to anchor to)."
                                             : "✓ Calibrated: \(done.joined(separator: " · ")) tokens/window"
        load(); onChange()
    }
    @objc func resetDefaults() { Cfg.resetAll(); load(); onChange() }
    @objc func closeWindow() { window?.orderOut(nil) }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    let settings = SettingsWindow()
    let menu = NSMenu()
    let refreshQueue = DispatchQueue(label: "aicreditsbar.refresh", qos: .utility)
    var latest: [ProviderStatus] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        statusItem.button?.title = "AI …"
        menu.delegate = self
        statusItem.menu = menu
        settings.onChange = { [weak self] in self?.refresh(); self?.rescheduleTimer() }
        refresh(); rescheduleTimer()
        if CommandLine.arguments.contains("--settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.openSettings() }
        }
    }
    func rescheduleTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: Cfg.refreshInterval, repeats: true) { [weak self] _ in self?.refresh() }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
    @objc func manualRefresh() { refresh() }
    @objc func openSettings() { settings.show() }

    func refresh() {
        refreshQueue.async {
            let providers = [readCodex(), readClaude(), readGemini()]
            DispatchQueue.main.async { self.latest = providers; self.renderTitle(providers) }
        }
    }
    func renderTitle(_ all: [ProviderStatus]) {
        let shown = zip(all, [Cfg.showCodex, Cfg.showClaude, Cfg.showGemini]).filter { $0.1 }.map { $0.0 }
        let title = NSMutableAttributedString()
        let sep = NSAttributedString(string: "  ·  ", attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor])
        for (i, p) in shown.enumerated() { if i > 0 { title.append(sep) }; title.append(barSegment(p)) }
        if title.length == 0 { title.append(NSAttributedString(string: "AICreditsBar")) }
        statusItem.button?.attributedTitle = title
    }

    // Build the dropdown lazily so it's never swapped while open.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for p in latest {
            let planTxt = p.plan.map { " — \($0)" } ?? ""
            menu.addItem(headerItem("\(p.name)\(planTxt)\(p.throttled ? "  ⚠︎ throttled" : "")"))
            if !p.available { menu.addItem(detail("   \(p.problem ?? "unavailable")")) }
            else {
                if let f = p.fiveHour { menu.addItem(detail("   " + winLine("5h", f, age: p.snapshotAge))) }
                if let w = p.weekly { menu.addItem(detail("   " + winLine(p.name == "Claude" ? "7d" : "week", w, age: p.snapshotAge))) }
                for dd in p.details { menu.addItem(detail("   \(dd)")) }
                if let a = p.snapshotAge { menu.addItem(detail("   snapshot \(ageLabel(a))")) }
            }
            menu.addItem(.separator())
        }
        let setItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","); setItem.target = self; menu.addItem(setItem)
        let refreshItem = NSMenuItem(title: "Refresh now", action: #selector(manualRefresh), keyEquivalent: "r"); refreshItem.target = self; menu.addItem(refreshItem)
        menu.addItem(NSMenuItem(title: "Quit AICreditsBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }
    func menuWillOpen(_ menu: NSMenu) { refresh() }   // freshen for next open + title

    func winLine(_ label: String, _ w: WindowStat, age: Double?) -> String {
        if w.refilled { return "\(label): refilled ✓" + (w.note.map { " (\($0))" } ?? "") }
        if w.stale { return "\(label): \(w.remaining ?? 0)% — stale (data \(ageLabel(age)))" }
        var s = "\(label): \(w.remaining ?? 0)% left"
        if let n = w.note { s += "  (\(n))" }
        if w.resetEpoch != nil { s += "  · reset \(resetLabel(w.resetEpoch))" }
        return s
    }
    func headerItem(_ s: String) -> NSMenuItem {
        let it = NSMenuItem(title: s, action: nil, keyEquivalent: ""); it.isEnabled = false
        it.attributedTitle = NSAttributedString(string: s, attributes: [.font: NSFont.boldSystemFont(ofSize: 12), .foregroundColor: NSColor.labelColor]); return it
    }
    func detail(_ s: String) -> NSMenuItem {
        let it = NSMenuItem(title: s, action: nil, keyEquivalent: ""); it.isEnabled = false
        it.attributedTitle = NSAttributedString(string: s, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]); return it
    }
}

// MARK: - Entry

// CLI calibration: `--set-week-used 52` / `--set-5h-used 80` — derive the Claude budget
// from the app's own token sums so the window shows (100 - used)% to match `/usage`.
func argValue(_ flag: String) -> Double? {
    guard let i = CommandLine.arguments.firstIndex(of: flag), i + 1 < CommandLine.arguments.count else { return nil }
    return Double(CommandLine.arguments[i + 1])
}
if let pct = argValue("--set-week-used") {
    let sums = claudeCalibrationSums()
    guard pct > 0, pct <= 100, sums.week > 0 else { print("need 0<pct<=100 and some Claude usage (7d tokens=\(tokLabel(sums.week)))"); exit(1) }
    Cfg.claudeWeekBudget = sums.week / (pct / 100); Cfg.d.synchronize()
    print("Claude weekly calibrated: 7d=\(tokLabel(sums.week)) tok @ \(Int(pct))% used → budget \(tokLabel(Cfg.claudeWeekBudget)), shows \(100 - Int(pct))% left")
    exit(0)
}
if let pct = argValue("--set-5h-used") {
    let sums = claudeCalibrationSums()
    guard pct > 0, pct <= 100, sums.five > 0 else { print("need 0<pct<=100 and an active Claude 5h block (5h tokens=\(tokLabel(sums.five)))"); exit(1) }
    Cfg.claudePlan = "Custom"; Cfg.claude5hBudget = sums.five / (pct / 100); Cfg.d.synchronize()
    print("Claude 5h calibrated: 5h=\(tokLabel(sums.five)) tok @ \(Int(pct))% used → budget \(tokLabel(Cfg.claude5hBudget)), shows \(100 - Int(pct))% left")
    exit(0)
}

if CommandLine.arguments.contains("--once") || CommandLine.arguments.contains("--dump-config") {
    if CommandLine.arguments.contains("--dump-config") {
        print("displayMode=\(Cfg.displayMode) labels=\(Cfg.showLabels) refresh=\(Int(Cfg.refreshInterval))s")
        print("providers: Cx=\(Cfg.showCodex) Cl=\(Cfg.showClaude) Gm=\(Cfg.showGemini)")
        print("thresholds: green>\(Cfg.greenAbove) yellow>=\(Cfg.yellowAbove)")
        print("colors: high=\(Cfg.colorHigh.hexString) mid=\(Cfg.colorMid.hexString) low=\(Cfg.colorLow.hexString) unknown=\(Cfg.colorUnknown.hexString)")
        print("claude: plan=\(Cfg.claudePlan) 5h=\(tokLabel(Cfg.claude5hBudget)) week=\(tokLabel(Cfg.claudeWeekBudget))")
    }
    for p in [readCodex(), readClaude(), readGemini()] {
        var line = "\(p.name): "
        if !p.available { line += "[unavailable] \(p.problem ?? "")" }
        else {
            if let f = p.fiveHour { line += "5h=" + (f.refilled ? "refilled" : (f.stale ? "\(f.remaining ?? 0)%(stale)" : "\(f.remaining ?? 0)%")) + (f.note.map { " (\($0))" } ?? "") }
            if let w = p.weekly { line += "  \(p.name == "Claude" ? "7d" : "week")=" + (w.refilled ? "refilled" : "\(w.remaining ?? 0)%") }
            if let pl = p.plan { line += "  [\(pl)]" }
            if p.throttled { line += "  THROTTLED" }
            if let a = p.snapshotAge { line += "  (snapshot \(ageLabel(a)))" }
        }
        print(line)
    }
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
