import Foundation

// MARK: - Helpers shared by the providers, the UI and the CLI

let HOME = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
let userAgent = "AICreditsBar/2.0"
func nowEpoch() -> Double { Date().timeIntervalSince1970 }

/// Double → Int in [0, 100]. Never call Int() on an unvalidated Double:
/// Int(NaN/inf) traps, and these numbers come from JSON we don't control.
func pctClamp(_ d: Double) -> Int { d.isFinite ? Int(min(100, max(0, d)).rounded()) : 0 }

/// Drop a non-finite, non-positive or absurd (> year 2100) epoch.
func sanitizeEpoch(_ e: Double?) -> Double? { e.flatMap { ($0.isFinite && $0 > 0 && $0 < 4_102_444_800) ? $0 : nil } }

func parseISO(_ s: String) -> Double? {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = f.date(from: s) { return date.timeIntervalSince1970 }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)?.timeIntervalSince1970
}

// MARK: JSON

func jsonObject(_ data: Data?) -> [String: Any]? {
    guard let data = data else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

/// A JSON number, or a number sent as a string ("58600.48").
func number(_ value: Any?) -> Double? {
    if let n = value as? NSNumber { return n.doubleValue.isFinite ? n.doubleValue : nil }
    if let s = value as? String, let d = Double(s), d.isFinite { return d }
    return nil
}

// MARK: Labels

/// "pro" → "Pro"
func displayPlan(_ raw: String) -> String { raw.prefix(1).uppercased() + raw.dropFirst() }

/// A window named by its length: 18000 s → "5-hour", 604800 s → "Weekly".
func windowLabel(seconds: Double?) -> String {
    guard let s = seconds, s > 0, s < 1e9 else { return "Usage limit" }   // bounded before any Int()
    let days = s / 86400, hours = s / 3600
    if days == 7 { return "Weekly" }
    if days == 1 { return "Daily" }
    if days > 1, days == days.rounded() { return "\(Int(days))-day" }
    if hours == hours.rounded() { return "\(Int(hours))-hour" }
    return "\(Int((s / 60).rounded()))-minute"
}

func windowKind(seconds: Double?) -> WindowKind {
    guard let s = seconds, s > 0 else { return .other }
    if s <= 86400 { return .session }
    if s >= 6 * 86400 && s <= 8 * 86400 { return .weekly }
    return .other
}

/// Time until a future moment: "in 45m", "in 2h 31m", "in 5d 19h".
func countdown(to epoch: Double, now: Double = nowEpoch()) -> String {
    let seconds = epoch - now
    guard seconds >= 60 else { return "in <1m" }
    let minutes = Int(min(seconds, 1e9) / 60)
    if minutes < 60 { return "in \(minutes)m" }
    if minutes < 1440 { return "in \(minutes / 60)h \(minutes % 60)m" }
    return "in \(minutes / 1440)d \(minutes % 1440 / 60)h"
}

/// Age of a reading: "just now", "4m ago", "3h ago", "2d ago".
func ago(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 60 else { return "just now" }
    let minutes = Int(min(seconds, 1e9) / 60)
    if minutes < 60 { return "\(minutes)m ago" }
    if minutes < 1440 { return "\(minutes / 60)h ago" }
    return "\(minutes / 1440)d ago"
}

/// "Thu, Oct 17, 9:00 AM" in the user's locale — for tooltips.
func absoluteTime(_ epoch: Double) -> String {
    let f = DateFormatter()
    f.setLocalizedDateFormatFromTemplate("EEE MMM d j:mm")
    return f.string(from: Date(timeIntervalSince1970: epoch))
}

func groupedNumber(_ value: Double) -> String {
    let f = NumberFormatter()
    f.locale = Locale(identifier: "en_US")
    f.numberStyle = .decimal
    f.maximumFractionDigits = 0
    f.roundingMode = .down
    return f.string(from: NSNumber(value: value)) ?? String(format: "%.0f", value)
}

// MARK: Network and Keychain (background queue only — both block)

private let session: URLSession = {
    let config = URLSessionConfiguration.ephemeral   // no cookies or cache written to disk
    config.timeoutIntervalForRequest = 20
    config.timeoutIntervalForResource = 30
    return URLSession(configuration: config)
}()

func httpGet(_ url: String, headers: [String: String]) throws -> (status: Int, body: Data) {
    guard let target = URL(string: url) else { throw UsageError("Bad URL \(url)") }
    var request = URLRequest(url: target)
    request.cachePolicy = .reloadIgnoringLocalCacheData
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    var response: (Int, Data)?
    let done = DispatchSemaphore(value: 0)
    session.dataTask(with: request) { data, reply, _ in
        if let http = reply as? HTTPURLResponse { response = (http.statusCode, data ?? Data()) }
        done.signal()
    }.resume()
    done.wait()
    guard let (status, body) = response else {
        throw UsageError("Can't reach \(target.host ?? url)", hint: "Check the internet connection.")
    }
    return (status, body)
}

/// A generic-password secret, read with /usr/bin/security. Claude Code saves
/// its login with that same tool, so macOS hands it over without a prompt.
func keychainSecret(service: String) -> Data? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    process.arguments = ["find-generic-password", "-s", service, "-w"]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return process.terminationStatus == 0 && !data.isEmpty ? data : nil
}
