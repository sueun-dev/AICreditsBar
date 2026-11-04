import Foundation

// MARK: - Usage forecast
//
// Everything here is an ESTIMATE built from the provider-reported percentages
// the app already reads. It never changes those numbers, and the menu labels
// it as an estimate. The pieces are pure functions so they can be tested
// without a network, a login or the UI.

/// Claude model families, cheapest first.
enum ModelFamily: String, CaseIterable, Codable {
    case haiku = "Haiku", sonnet = "Sonnet", opus = "Opus"

    /// Relative cost of one hour of use. An assumption taken from API price
    /// ratios — the provider doesn't publish how the model moves a plan limit,
    /// so Settings lets you change these.
    var defaultWeight: Double {
        switch self {
        case .haiku: return 1
        case .sonnet: return 3
        case .opus: return 5
        }
    }
    var rank: Int { ModelFamily.allCases.firstIndex(of: self) ?? 0 }
}

struct ForecastSettings: Equatable {
    var baseline: ModelFamily = .sonnet          // the model the observed pace was spent on
    var version = "5.5"
    var weights: [ModelFamily: Double] = Dictionary(uniqueKeysWithValues: ModelFamily.allCases.map { ($0, $0.defaultWeight) })

    func title(_ model: ModelFamily) -> String { "\(model.rawValue) \(version)" }
    /// How much faster `model` uses the limit than the model the pace was measured on.
    func scale(_ model: ModelFamily) -> Double {
        let base = weights[baseline] ?? baseline.defaultWeight, this = weights[model] ?? model.defaultWeight
        return base > 0 && this > 0 ? this / base : 1
    }
}

// MARK: - History

struct UsageSample: Codable, Equatable {
    var t: Double      // unix seconds
    var used: Double   // 0–100, as the provider reported
}

/// The readings of each window's current cycle, kept so the pace of recent use
/// can be measured. A new cycle (the reset moved on, or the figure fell) starts over.
struct UsageHistory {
    struct Series: Codable, Equatable {
        var reset: Double?
        var samples: [UsageSample]
    }
    static let bucket: Double = 900        // one sample per 15 minutes
    static let maxSamples = 700            // a week of buckets, with slack

    private(set) var series: [String: Series]

    init(data: Data? = nil) {
        series = data.flatMap { try? JSONDecoder().decode([String: Series].self, from: $0) } ?? [:]
    }
    var data: Data? { try? JSONEncoder().encode(series) }

    static func key(_ provider: Provider, _ window: UsageWindow) -> String {
        "\(provider.rawValue):\(window.kind.rawValue):\(window.modelScoped):\(window.label)"
    }
    func samples(_ provider: Provider, _ window: UsageWindow) -> [UsageSample] {
        series[Self.key(provider, window)]?.samples ?? []
    }

    /// Returns whether anything changed (so the caller only saves when it must).
    @discardableResult
    mutating func record(_ reading: Reading, provider: Provider, now: Double) -> Bool {
        guard reading.fetchedAt.isFinite, reading.fetchedAt <= now + 5, now - reading.fetchedAt <= 60 else { return false }
        let before = series
        let prefix = provider.rawValue + ":"
        var present = Set<String>()
        for window in reading.windows {
            let key = Self.key(provider, window)
            guard present.insert(key).inserted, window.usedPercent.isFinite, (0...100).contains(window.usedPercent),
                  !window.isExpired(now: now) else { continue }
            var entry = series[key] ?? Series(reset: window.resetsAt, samples: [])
            if let old = entry.reset, let new = window.resetsAt, new > old + 60 { entry = Series(reset: new, samples: []) }
            if let last = entry.samples.last, window.usedPercent < last.used - 0.01 {
                entry = Series(reset: window.resetsAt, samples: [])
            }
            entry.reset = window.resetsAt ?? entry.reset
            let sample = UsageSample(t: reading.fetchedAt, used: window.usedPercent)
            if let last = entry.samples.last {
                if sample.t > last.t {
                    if (sample.t / Self.bucket).rounded(.down) == (last.t / Self.bucket).rounded(.down) {
                        // Same 15 minutes: keep the latest figure, and write nothing if it hasn't moved.
                        if sample.used != last.used { entry.samples[entry.samples.count - 1] = sample }
                    } else {
                        entry.samples.append(sample)
                    }
                }
            } else {
                entry.samples.append(sample)
            }
            if entry.samples.count > Self.maxSamples { entry.samples.removeFirst(entry.samples.count - Self.maxSamples) }
            series[key] = entry
        }
        // A window the provider stops reporting is dropped once its cycle is over.
        series = series.filter { key, entry in
            guard key.hasPrefix(prefix), !present.contains(key) else { return true }
            return (entry.reset ?? ((entry.samples.last?.t ?? 0) + 8 * 86400)) > now
        }
        return series != before
    }

    /// The reported figure at `t`, interpolated between the two readings around
    /// it — nil when no pair of readings within `maxGap` seconds brackets it.
    static func value(at t: Double, in samples: [UsageSample], maxGap: Double = 2700) -> Double? {
        guard t.isFinite, let first = samples.first, let last = samples.last, t >= first.t, t <= last.t else { return nil }
        var before = first
        for next in samples {
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
}

// MARK: - Forecast of one window

struct WindowForecast: Equatable {
    var label: String
    var kind: WindowKind
    var left: Double                  // % remaining
    var resetsAt: Double
    var avgPerHour: Double            // % per hour averaged over the cycle so far, idle time included
    var activePerHour: Double?        // % per hour during hours of actual use
    var usedToday: Double?            // % used since local midnight
    var learning: Bool                // too little of the cycle has passed for a firm forecast

    func resetsIn(now: Double) -> Double { max(0, resetsAt - now) }
    /// Left at the reset if the cycle's average pace continues (negative = runs out first).
    func projectedLeftAtReset(now: Double) -> Double { left - avgPerHour * resetsIn(now: now) / 3600 }
    /// Seconds until empty at the average pace, only when that is before the reset.
    func runsOutIn(now: Double) -> Double? {
        guard avgPerHour > 0.0001 else { return nil }
        let seconds = left / avgPerHour * 3600
        return seconds < resetsIn(now: now) ? seconds : nil
    }
    /// Hours of nonstop use left. `scale` is the model's cost against the one the pace was measured on.
    func hoursOfUse(scale: Double = 1) -> Double? {
        guard let rate = activePerHour ?? (kind == .session ? avgPerHour : nil), rate * scale > 0.0001 else { return nil }
        return left / (rate * scale)
    }
}

/// What the menu shows for a provider's forecast, already worded.
struct ModelAdvice: Equatable {
    enum Tone { case good, watch, critical, neutral }
    var model: ModelFamily?
    var headline: String
    var detail: String
    var tone: Tone
}

struct ForecastLine: Equatable {
    enum Style { case headline, detail, pace, caption, hours }
    var text: String
    var style: Style
    var tone: ModelAdvice.Tone = .neutral
}

struct ForecastSummary: Equatable {
    var advice: ModelAdvice?
    var lines: [ForecastLine]
}

enum Forecaster {
    static func windowLength(_ window: UsageWindow) -> Double? {
        if let length = window.length, length.isFinite, length > 0 { return length }
        switch window.kind {
        case .session: return 5 * 3600
        case .weekly: return 7 * 86400
        case .other: return nil
        }
    }

    static func forecast(_ window: UsageWindow, samples: [UsageSample], now: Double,
                         calendar: Calendar = .current) -> WindowForecast? {
        guard !window.modelScoped, !window.isExpired(now: now), window.usedPercent.isFinite,
              (0...100).contains(window.usedPercent), let reset = window.resetsAt,
              let length = windowLength(window) else { return nil }
        let start = reset - length
        let elapsed = min(length, now - start)
        guard elapsed > 60 else { return nil }
        let used = window.usedPercent
        let learning = window.kind == .weekly ? (elapsed < 86400 || used < 2) : (elapsed < 1200 || used < 1)
        let cycle = samples.filter { $0.t >= start - 60 }
        var result = WindowForecast(label: window.label, kind: window.kind, left: 100 - used, resetsAt: reset,
                                    avgPerHour: used / (elapsed / 3600), activePerHour: nil, usedToday: nil,
                                    learning: learning)
        result.activePerHour = activeRate(cycle, kind: window.kind, from: window.kind == .weekly ? now - 72 * 3600 : start, now: now)
        let midnight = calendar.startOfDay(for: Date(timeIntervalSince1970: now)).timeIntervalSince1970
        if midnight <= start {
            result.usedToday = used   // the cycle began today
        } else if let base = UsageHistory.value(at: midnight, in: cycle, maxGap: 10 * 3600) {
            result.usedToday = max(0, used - base)
        }
        return result
    }

    /// Percent per hour during the hours something was used: whole hours (half
    /// hours for the 5-hour window) in which the figure rose, and nothing else.
    static func activeRate(_ samples: [UsageSample], kind: WindowKind, from: Double, now: Double) -> Double? {
        let size: Double = kind == .session ? 1800 : 3600
        var t = (from / size).rounded(.up) * size
        var active = 0, gained = 0.0
        while t + size <= now {
            if let a = UsageHistory.value(at: t, in: samples), let b = UsageHistory.value(at: t + size, in: samples), b - a >= 0.5 {
                active += 1
                gained += b - a
            }
            t += size
        }
        return active > 0 ? gained / (Double(active) * size / 3600) : nil
    }

    // MARK: Advice

    /// Which model the weekly limit can afford, given how fast it has been spent.
    static func advice(weekly w: WindowForecast, settings: ForecastSettings, now: Double) -> ModelAdvice {
        let base = settings.baseline
        let name = settings.title
        if w.left < 0.5 {
            return ModelAdvice(model: nil, headline: "Weekly limit used up",
                               detail: "It resets \(countdown(to: w.resetsAt, now: now)).", tone: .critical)
        }
        if w.learning {
            return ModelAdvice(model: base, headline: "Keep \(name(base))",
                               detail: "Still learning your pace — it takes about a day of use.", tone: .neutral)
        }
        let daysLeft = max(w.resetsIn(now: now) / 86400, 1.0 / 24)
        let budget = w.left / daysLeft                       // % per day that can be spent
        let typical = w.avgPerHour * 24                      // % per day spent so far, on `base`
        func need(_ model: ModelFamily) -> Double { typical * settings.scale(model) }
        let margin = 1.15

        guard let pick = ModelFamily.allCases.reversed().first(where: { need($0) * margin <= budget }) else {
            let cheapest = ModelFamily.allCases.min { settings.scale($0) < settings.scale($1) } ?? .haiku
            let hours = need(cheapest) > 0 ? w.left / need(cheapest) * 24 : 0
            let short = max(0, w.resetsIn(now: now) - hours * 3600)
            return ModelAdvice(model: cheapest, headline: "Go easy — even \(name(cheapest)) runs short",
                               detail: "At that pace it ends ≈\(durationText(short)) before the reset. Can spend ≈\(percentText(budget))/day.",
                               tone: .critical)
        }
        if pick == base {
            return ModelAdvice(model: pick, headline: "Stay on \(name(pick))",
                               detail: "Can spend ≈\(percentText(budget))/day · you use ≈\(percentText(typical))/day",
                               tone: .good)
        }
        if pick.rank > base.rank {
            return ModelAdvice(model: pick, headline: "\(name(pick)) is fine today",
                               detail: "Can spend ≈\(percentText(budget))/day · \(name(pick)) pace ≈\(percentText(need(pick)))/day",
                               tone: .good)
        }
        return ModelAdvice(model: pick, headline: "Use \(name(pick)) from now on",
                           detail: "Can spend ≈\(percentText(budget))/day · \(name(base)) pace is ≈\(percentText(typical))/day",
                           tone: .watch)
    }

    // MARK: Summary for the menu

    /// Only a current reading is projected forward; a stale, restored or failed one isn't.
    static func summary(provider: Provider, state: ProviderState, history: UsageHistory, now: Double) -> ForecastSummary? {
        guard Cfg.forecastEnabled, state.isCurrent(now: now), let reading = state.reading else { return nil }
        return summary(provider: provider, reading: reading, history: history, settings: Cfg.forecastSettings, now: now)
    }

    static func summary(provider: Provider, reading: Reading, history: UsageHistory,
                        settings: ForecastSettings, now: Double) -> ForecastSummary? {
        let general = reading.windows.filter { !$0.modelScoped && !$0.isExpired(now: now) }
        func pick(_ kind: WindowKind) -> WindowForecast? {
            general.filter { $0.kind == kind }
                .compactMap { forecast($0, samples: history.samples(provider, $0), now: now) }
                .min { $0.resetsAt < $1.resetsAt }
        }
        let session = pick(.session), weekly = pick(.weekly)
        guard session != nil || weekly != nil else { return nil }

        var lines: [ForecastLine] = []
        var advice: ModelAdvice?
        if provider == .claude, let weekly = weekly {
            let found = self.advice(weekly: weekly, settings: settings, now: now)
            advice = found
            lines.append(ForecastLine(text: found.headline, style: .headline, tone: found.tone))
            lines.append(ForecastLine(text: found.detail, style: .detail))
        }
        for window in [weekly, session].compactMap({ $0 }) {
            lines.append(paceLine(window, now: now))
        }
        if provider == .claude {
            var hours: [ForecastLine] = []
            for window in [session, weekly].compactMap({ $0 }) {
                let parts = ModelFamily.allCases.compactMap { model -> String? in
                    window.hoursOfUse(scale: settings.scale(model)).map { "\(model.rawValue) \(durationText($0 * 3600))" }
                }
                if parts.count == ModelFamily.allCases.count {
                    hours.append(ForecastLine(text: "\(window.kind == .session ? "5-hour" : "Weekly")  " + parts.joined(separator: " · "),
                                              style: .hours))
                }
            }
            if !hours.isEmpty {
                lines.append(ForecastLine(text: "Hours of nonstop use left", style: .caption))
                lines += hours
            }
        }
        return ForecastSummary(advice: advice, lines: lines)
    }

    private static func paceLine(_ w: WindowForecast, now: Double) -> ForecastLine {
        let name = w.kind == .session ? "5-hour" : "Weekly"
        if w.learning { return ForecastLine(text: "\(name): still learning your pace", style: .pace) }
        if let out = w.runsOutIn(now: now) {
            let before = w.resetsIn(now: now) - out
            let tone: ModelAdvice.Tone = before > (w.kind == .weekly ? 86400 : 3600) ? .critical : .watch
            return ForecastLine(text: "\(name): runs out in \(durationText(out)), \(durationText(before)) before the reset",
                                style: .pace, tone: tone)
        }
        if w.avgPerHour <= 0.0001 { return ForecastLine(text: "\(name): not used yet this cycle", style: .pace, tone: .good) }
        return ForecastLine(text: "\(name): on track · ≈\(percentText(max(0, w.projectedLeftAtReset(now: now)))) left at the reset",
                            style: .pace, tone: .good)
    }
}

// MARK: - Wording

/// "4.0%", "0.6%", "12%" — one decimal below 10.
func percentText(_ value: Double) -> String {
    guard value.isFinite else { return "0%" }
    let v = min(1000, max(0, value))
    return v >= 10 ? "\(Int(v.rounded()))%" : (v == 0 ? "0%" : String(format: "%.1f%%", v))
}

/// "35m", "3h 20m", "21h", "2d 4h" — never traps on a non-finite or huge value.
func durationText(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "—" }
    let minutes = Int(min(max(seconds, 0), 1e8) / 60)
    if minutes < 1 { return "<1m" }
    if minutes < 60 { return "\(minutes)m" }
    if minutes < 600 { return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m" }
    if minutes < 2880 { return "\(minutes / 60)h" }
    return minutes % 1440 < 60 ? "\(minutes / 1440)d" : "\(minutes / 1440)d \(minutes % 1440 / 60)h"
}
