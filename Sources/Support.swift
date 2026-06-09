import AppKit

// MARK: - Helpers

let HOME = ProcessInfo.processInfo.environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
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
