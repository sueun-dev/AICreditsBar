import Foundation

// MARK: - Checking the forecast against what actually happened
//
// The forecast is an estimate, so the app keeps the readings it gets and, once
// enough time has passed, compares its own earlier predictions with the readings
// that followed. Two checks, both from real data only:
//   - pace: the used % it predicted 24 hours ahead from the cycle's average pace
//     against the used % that was then reported;
//   - model costs: the % that the priced Claude Code tokens predicted for the
//     next 6 hours against the % that was then reported. This is the check on the
//     one assumption the per-model numbers rest on — that a limit is used up in
//     proportion to the API price of the tokens.
// Nothing here changes a forecast; it only says how far off the forecasts were.

struct SampleLog: Codable, Equatable {
    struct Point: Codable, Equatable {
        var t: Double       // unix seconds
        var used: Double    // % used, as reported
    }
    struct Series: Codable, Equatable {
        var provider: String
        var kind: Int
        var length: Double
        var reset: Double
        var points: [Point]

        /// When the reported figure last fell inside this cycle: the limit was reset (a reset
        /// coupon takes 98% to 0% without moving the reset time). The first reading after the
        /// drop dates it.
        var refill: Double? {
            var found: Double?
            for i in points.indices.dropFirst() where SampleLog.isReset(from: points[i - 1].used, to: points[i].used) { found = points[i].t }
            return found
        }

        /// The use that resets have wiped from the counter, so the use before a reset is carried over
        /// instead of thrown away. A reset to (nearly) zero wipes all of what the counter showed.
        var refunded: Double { SampleLog.refund(points) }

        /// The reported figures with that wiped use added back: one curve that keeps rising across a reset.
        var cumulative: [Point] {
            var offset = 0.0
            var out: [Point] = []
            for i in points.indices {
                if i > 0, SampleLog.isReset(from: points[i - 1].used, to: points[i].used) { offset += SampleLog.wiped(from: points[i - 1].used, to: points[i].used) }
                out.append(Point(t: points[i].t, used: points[i].used + offset))
            }
            return out
        }
    }
    static let bucket = 900.0          // one reading per 15 minutes
    static let maxPoints = 700         // a week of buckets, with slack
    static let horizon = 7 * 86400.0   // nothing older than a week is kept
    static let refillDrop = 2.0        // a fall of more than this many points is a reset, not a rounding wobble

    static func isReset(from: Double, to: Double) -> Bool { to < from - refillDrop }
    /// How much a fall wiped from the counter: all of it when it fell to (nearly) zero, else the difference.
    static func wiped(from: Double, to: Double) -> Double { to <= 10 ? from : from - to }
    static func refund(_ points: [Point]) -> Double {
        var total = 0.0
        for i in points.indices.dropFirst() where isReset(from: points[i - 1].used, to: points[i].used) { total += wiped(from: points[i - 1].used, to: points[i].used) }
        return total
    }

    private(set) var series: [String: Series] = [:]

    init(data: Data? = nil) {
        series = data.flatMap { try? JSONDecoder().decode([String: Series].self, from: $0) } ?? [:]
    }
    var data: Data? { try? JSONEncoder().encode(series) }

    private func series(_ provider: Provider, _ window: UsageWindow) -> Series? {
        guard let reset = window.resetsAt else { return nil }
        return series["\(provider.rawValue)|\(window.kind.rawValue)|\(window.label)|\(Int((reset / 60).rounded()))"]
    }
    /// When this window's current cycle was last reset mid-cycle, if its readings show it.
    func refill(provider: Provider, window: UsageWindow) -> Double? { series(provider, window)?.refill }
    /// The use before such resets, to carry over.
    func refunded(provider: Provider, window: UsageWindow) -> Double { series(provider, window)?.refunded ?? 0 }

    /// Returns whether anything changed, so the caller only saves when it must.
    @discardableResult
    mutating func record(_ reading: Reading, provider: Provider, now: Double) -> Bool {
        guard reading.fetchedAt.isFinite, reading.fetchedAt <= now + 5, now - reading.fetchedAt <= 60 else { return false }
        let before = series
        for window in reading.windows {
            guard !window.modelScoped, window.usedPercent.isFinite, (0...100).contains(window.usedPercent),
                  !window.isExpired(now: now), let reset = window.resetsAt,
                  let length = Forecaster.windowLength(window) else { continue }
            // The reset time jitters by milliseconds between readings: a cycle is keyed by its minute.
            let key = "\(provider.rawValue)|\(window.kind.rawValue)|\(window.label)|\(Int((reset / 60).rounded()))"
            var entry = series[key] ?? Series(provider: provider.rawValue, kind: window.kind.rawValue, length: length, reset: reset, points: [])
            let point = Point(t: reading.fetchedAt, used: window.usedPercent)
            if let last = entry.points.last {
                guard point.t > last.t else { continue }
                if (point.t / Self.bucket).rounded(.down) == (last.t / Self.bucket).rounded(.down) {
                    if point.used != last.used { entry.points[entry.points.count - 1] = point }   // same 15 minutes: the latest figure
                } else {
                    entry.points.append(point)
                }
            } else {
                entry.points.append(point)
            }
            if entry.points.count > Self.maxPoints { entry.points.removeFirst(entry.points.count - Self.maxPoints) }
            series[key] = entry
        }
        series = series.filter { $0.value.reset > now - Self.horizon }
        return series != before
    }
}

struct AccuracyReport: Equatable {
    var paceChecks = 0
    var paceMissPoints = 0.0       // median |predicted − actual| used %, 24 hours ahead
    var paceBiasPoints = 0.0       // mean (predicted − actual): positive = the forecast ran too high
    var costChecks = 0
    var costRatio = 1.0            // real % burned ÷ the % the priced tokens predicted (1.0 = exact)

    static let minimumChecks = 3
    var hasPace: Bool { paceChecks >= Self.minimumChecks }
    var hasCost: Bool { costChecks >= Self.minimumChecks }
}

enum Accuracy {
    /// The reported figure at `t`, interpolated between the readings around it; nil across a long gap.
    static func value(at t: Double, in points: [SampleLog.Point], maxGap: Double = 2700) -> Double? {
        guard t.isFinite, let first = points.first, let last = points.last, t >= first.t, t <= last.t else { return nil }
        var before = first
        for next in points {
            if next.t >= t {
                if next.t == t { return next.used }
                if t == before.t { return before.used }
                guard next.t - before.t <= maxGap, next.t > before.t else { return nil }
                return before.used + (next.used - before.used) * (t - before.t) / (next.t - before.t)
            }
            before = next
        }
        return nil
    }

    static func report(_ log: SampleLog, provider: Provider, kind: WindowKind, ledger: UsageLedger?, now: Double) -> AccuracyReport {
        let paceAhead = kind == .session ? 3600.0 : 86400.0, costAhead = kind == .session ? 3600.0 : 6 * 3600.0
        let spacing = kind == .session ? 1800.0 : 3600.0   // one check per half hour / hour keeps them from repeating each other
        var misses: [Double] = [], signed: [Double] = []
        var actualSum = 0.0, predictedSum = 0.0, costChecks = 0
        for series in log.series.values where series.provider == provider.rawValue && series.kind == kind.rawValue {
            let points = series.cumulative   // keeps rising across a reset, like the forecast does
            let start = series.reset - series.length, last = points.last?.t ?? 0
            var next = start
            for point in points where point.t >= next {
                next = point.t + spacing
                let elapsed = point.t - start
                guard elapsed > 60, !Forecaster.isLearning(kind, elapsed: elapsed, used: point.used) else { continue }
                if point.t + paceAhead <= min(last, series.reset), let actual = value(at: point.t + paceAhead, in: points) {
                    let predicted = point.used * (1 + paceAhead / elapsed)
                    misses.append(abs(predicted - actual)); signed.append(predicted - actual)
                }
                guard let ledger = ledger, provider == .claude, start >= now - UsageLedger.horizon, point.used >= 2,
                      point.t + costAhead <= min(last, series.reset),
                      let later = value(at: point.t + costAhead, in: points) else { continue }
                let spent = ledger.slice(from: start, to: point.t).actualCost
                guard spent >= 1 else { continue }
                let predicted = point.used / spent * ledger.slice(from: point.t, to: point.t + costAhead).actualCost
                let actual = later - point.used
                if max(predicted, actual) >= 0.5 { actualSum += actual; predictedSum += predicted; costChecks += 1 }
            }
        }
        var result = AccuracyReport()
        result.paceChecks = misses.count
        if !misses.isEmpty {
            let sorted = misses.sorted()
            result.paceMissPoints = sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
            result.paceBiasPoints = signed.reduce(0, +) / Double(signed.count)
        }
        result.costChecks = costChecks
        if predictedSum > 0 { result.costRatio = actualSum / predictedSum }
        return result
    }

    /// The lines under the forecast: how far off the earlier forecasts were.
    static func lines(_ log: SampleLog?, provider: Provider, kind: WindowKind?, ledger: UsageLedger?, now: Double) -> [ForecastLine] {
        guard let log = log, let kind = kind else { return [] }
        let report = report(log, provider: provider, kind: kind, ledger: ledger, now: now)
        var lines: [ForecastLine] = []
        if report.hasPace {
            let high = report.paceBiasPoints > 0.5 ? " · ran high" : report.paceBiasPoints < -0.5 ? " · ran low" : ""
            lines.append(ForecastLine(text: "24h pace: off by \(points(report.paceMissPoints)) · \(report.paceChecks) checks\(high)", style: .detail))
        }
        if report.hasCost {
            lines.append(ForecastLine(text: "Model costs: real burn ×\(String(format: "%.2f", report.costRatio)) of priced · \(report.costChecks)", style: .detail))
        }
        if lines.isEmpty {
            return [ForecastLine(text: "Accuracy check: not enough data yet", style: .detail)]
        }
        return [ForecastLine(text: "Checked against what happened", style: .caption)] + lines
    }

    private static func points(_ value: Double) -> String { value >= 10 ? "\(Int(value.rounded())) pts" : String(format: "%.1f pts", value) }
}
