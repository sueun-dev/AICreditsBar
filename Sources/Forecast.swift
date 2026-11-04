import Foundation

// MARK: - Usage forecast
//
// Everything here is an ESTIMATE and is labeled as one. It is built from the
// provider-reported percentages the app already reads and, for Claude's model
// advice, from the tokens Claude Code wrote to this Mac (ModelUsage.swift). It
// never changes a reported number. The pieces are pure functions so they can be
// tested without a network, a login or the UI.

// MARK: - One window

struct WindowForecast: Equatable {
    var label: String
    var kind: WindowKind
    var used: Double                  // % used, as reported
    var resetsAt: Double
    var length: Double                // seconds the window spans
    var learning: Bool                // too little of the cycle has passed for a firm forecast

    var left: Double { 100 - used }
    var start: Double { resetsAt - length }
    func resetsIn(now: Double) -> Double { max(0, resetsAt - now) }
    func elapsed(now: Double) -> Double { max(1, min(length, now - start)) }
    /// % per hour averaged over the cycle so far, idle time included.
    func avgPerHour(now: Double) -> Double { used / (elapsed(now: now) / 3600) }
    /// Left at the reset if the cycle's average pace continues (negative = runs out first).
    func projectedLeftAtReset(now: Double) -> Double { left - avgPerHour(now: now) * resetsIn(now: now) / 3600 }
    /// Seconds until empty at the average pace, only when that is before the reset.
    func runsOutIn(now: Double) -> Double? {
        let rate = avgPerHour(now: now)
        guard rate > 0.0001 else { return nil }
        let seconds = left / rate * 3600
        return seconds < resetsIn(now: now) ? seconds : nil
    }
}

/// What one family would use if all of this cycle's work had run on it.
struct ModelEstimate: Equatable {
    var model: ModelFamily
    var pctPerDay: Double             // % of the limit per day, averaged over the cycle
    var hoursLeft: Double?            // hours of active use the remaining % lasts; nil when no active hours were measured
}

struct ModelProjection: Equatable {
    var estimates: [ModelEstimate]
    var dominant: ModelFamily?        // the family that did most of the work over the last 3 days
    func estimate(_ model: ModelFamily) -> ModelEstimate? { estimates.first { $0.model == model } }
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
    enum Style { case headline, detail, pace, caption, model }
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

    static func forecast(_ window: UsageWindow, now: Double) -> WindowForecast? {
        guard !window.modelScoped, !window.isExpired(now: now), window.usedPercent.isFinite,
              (0...100).contains(window.usedPercent), let reset = window.resetsAt,
              let length = windowLength(window) else { return nil }
        let elapsed = min(length, now - (reset - length))
        guard elapsed > 60 else { return nil }
        let used = window.usedPercent
        return WindowForecast(label: window.label, kind: window.kind, used: used, resetsAt: reset, length: length,
                              learning: isLearning(window.kind, elapsed: elapsed, used: used))
    }

    /// Too little of the cycle has passed, or too little is used, for a firm forecast.
    static func isLearning(_ kind: WindowKind, elapsed: Double, used: Double) -> Bool {
        kind == .session ? (elapsed < 1200 || used < 1) : (elapsed < 86400 || used < 2)
    }

    // MARK: Per-model projection

    /// The provider's % against the same cycle's tokens priced at published API
    /// rates gives the % of the limit one dollar of work uses; repricing those
    /// tokens per family says what the same work would have used on each.
    /// nil when there isn't enough of either to say.
    static func project(_ w: WindowForecast, ledger: UsageLedger, now: Double) -> ModelProjection? {
        guard !w.learning, w.used >= 2 else { return nil }
        let cycle = ledger.slice(from: w.start, to: now)
        guard cycle.actualCost >= 1 else { return nil }
        let perDollar = w.used / cycle.actualCost
        let days = max(1.0 / 24, w.elapsed(now: now) / 86400)
        let recent = ledger.slice(from: w.kind == .session ? w.start : max(w.start, now - 72 * 3600), to: now)
        let measured = recent.activeHours >= (w.kind == .session ? 1 : 2)
        let estimates = ModelFamily.allCases.map { family -> ModelEstimate in
            var hours: Double?
            if measured {
                let perHour = perDollar * (recent.repriced[family] ?? 0) / Double(recent.activeHours)
                if perHour > 1e-6 { hours = w.left / perHour }
            }
            return ModelEstimate(model: family, pctPerDay: perDollar * (cycle.repriced[family] ?? 0) / days, hoursLeft: hours)
        }
        let dominant = ledger.slice(from: now - 3 * 86400, to: now).actualByFamily.max { $0.value < $1.value }?.key
        return ModelProjection(estimates: estimates, dominant: dominant)
    }

    // MARK: Advice

    /// The strongest model the weekly limit can afford if all work ran on it, with a 15% margin.
    static func advice(weekly w: WindowForecast, projection: ModelProjection?, now: Double) -> ModelAdvice {
        if w.left < 0.5 {
            return ModelAdvice(model: nil, headline: "Weekly limit used up",
                               detail: "It resets \(countdown(to: w.resetsAt, now: now)).", tone: .critical)
        }
        guard !w.learning else {
            return ModelAdvice(model: nil, headline: "Not enough data yet",
                               detail: "It needs about a day of this week's use to measure your pace.", tone: .neutral)
        }
        guard let projection = projection else {
            return ModelAdvice(model: nil, headline: "Not enough data yet",
                               detail: "It needs Claude Code use on this Mac to compare models.", tone: .neutral)
        }
        let budget = w.left / max(w.resetsIn(now: now) / 86400, 1.0 / 24)     // % per day that can be spent
        func detail(_ estimate: ModelEstimate) -> String {
            "Can spend ≈\(percentText(budget))/day · \(estimate.model.rawValue) pace ≈\(percentText(estimate.pctPerDay))/day"
        }
        guard let pick = projection.estimates.reversed().first(where: { $0.pctPerDay * 1.15 <= budget }) else {
            let cheapest = projection.estimate(.haiku) ?? ModelEstimate(model: .haiku, pctPerDay: 0, hoursLeft: nil)
            return ModelAdvice(model: .haiku, headline: "Go easy — even \(cheapest.model.title) runs short",
                               detail: detail(cheapest), tone: .critical)
        }
        let name = pick.model.title
        guard let dominant = projection.dominant else {
            return ModelAdvice(model: pick.model, headline: "\(name) is affordable", detail: detail(pick), tone: .good)
        }
        if pick.model == dominant { return ModelAdvice(model: pick.model, headline: "Stay on \(name)", detail: detail(pick), tone: .good) }
        if pick.model.rank > dominant.rank {
            return ModelAdvice(model: pick.model, headline: "\(name) is fine today", detail: detail(pick), tone: .good)
        }
        return ModelAdvice(model: pick.model, headline: "Use \(name) from now on", detail: detail(pick), tone: .watch)
    }

    // MARK: Summary for the menu

    /// Only a current reading is projected forward; a stale, restored or failed one isn't.
    static func summary(provider: Provider, state: ProviderState, ledger: UsageLedger?, samples: SampleLog? = nil, now: Double) -> ForecastSummary? {
        guard Cfg.forecastEnabled, state.isCurrent(now: now), let reading = state.reading else { return nil }
        return summary(provider: provider, reading: reading, ledger: ledger, samples: samples, now: now)
    }

    static func summary(provider: Provider, reading: Reading, ledger: UsageLedger?, samples: SampleLog? = nil, now: Double) -> ForecastSummary? {
        let general = reading.windows.filter { !$0.modelScoped && !$0.isExpired(now: now) }
        func pick(_ kind: WindowKind) -> WindowForecast? {
            general.filter { $0.kind == kind }.compactMap { forecast($0, now: now) }.min { $0.resetsAt < $1.resetsAt }
        }
        let session = pick(.session), weekly = pick(.weekly)
        // Any other window the provider reports with a known length (e.g. a 30-day one).
        let others = general.filter { $0.kind == .other && $0.length != nil }.compactMap { forecast($0, now: now) }
        guard session != nil || weekly != nil || !others.isEmpty else { return nil }

        var lines: [ForecastLine] = []
        var advice: ModelAdvice?
        var projections: [WindowKind: ModelProjection] = [:]
        if provider == .claude, let ledger = ledger {
            for window in [weekly, session].compactMap({ $0 }) {
                projections[window.kind] = project(window, ledger: ledger, now: now)
            }
        }
        if provider == .claude, let weekly = weekly {
            let found = self.advice(weekly: weekly, projection: projections[.weekly], now: now)
            advice = found
            lines.append(ForecastLine(text: found.headline, style: .headline, tone: found.tone))
            lines.append(ForecastLine(text: found.detail, style: .detail))
        }
        for window in [weekly, session].compactMap({ $0 }) + others { lines.append(paceLine(window, now: now)) }
        if provider == .claude {
            for window in [weekly, session].compactMap({ $0 }) {
                let name = window.kind == .session ? "5-hour" : "Weekly"
                guard let projection = projections[window.kind] else {
                    lines.append(ForecastLine(text: "\(name) per model: not enough data yet", style: .model))
                    continue
                }
                lines.append(ForecastLine(text: "\(name) · pace and hours of use left", style: .caption))
                for estimate in projection.estimates {
                    lines.append(ForecastLine(text: modelRow(estimate, showPace: window.kind != .session), style: .model))
                }
            }
            if !projections.isEmpty {
                lines.append(ForecastLine(text: "Priced at API rates, matched to your own use", style: .detail))
            }
        }
        lines += Accuracy.lines(samples, provider: provider, kind: weekly?.kind ?? others.first?.kind, ledger: ledger, now: now)
        return ForecastSummary(advice: advice, lines: lines)
    }

    private static func modelRow(_ estimate: ModelEstimate, showPace: Bool) -> String {
        func pad(_ text: String, _ width: Int) -> String { text.padding(toLength: width, withPad: " ", startingAt: 0) }
        let pace = showPace ? pad("≈\(percentText(estimate.pctPerDay))/day", 12) : ""
        let hours = estimate.hoursLeft.map { "≈\(durationText($0 * 3600)) left" } ?? "—"
        return pad(estimate.model.title, 11) + pace + hours
    }

    private static func paceLine(_ w: WindowForecast, now: Double) -> ForecastLine {
        let name = w.kind == .session ? "5-hour" : w.kind == .weekly ? "Weekly" : w.label
        if w.learning { return ForecastLine(text: "\(name): not enough data yet", style: .pace) }
        if let out = w.runsOutIn(now: now) {
            let before = w.resetsIn(now: now) - out
            let tone: ModelAdvice.Tone = before > (w.kind == .session ? 3600 : 86400) ? .critical : .watch
            return ForecastLine(text: "\(name): ends ≈\(durationText(before)) early (at avg pace)",
                                style: .pace, tone: tone)
        }
        if w.avgPerHour(now: now) <= 0.0001 { return ForecastLine(text: "\(name): not used yet this cycle", style: .pace, tone: .good) }
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
