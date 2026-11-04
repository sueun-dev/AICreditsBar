import AppKit

/// The forecast is an estimate, so the tests pin down the arithmetic and the
/// wording a person acts on: which model is advised, and how many hours remain.
func runForecastTests(now: Double) {
    Cfg.resetAll()
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    let base = (now / 86400).rounded(.down) * 86400 + 6 * 3600   // 06:00 UTC, so "today" began 6 hours ago
    let settings = ForecastSettings()

    func weekly(used: Double, elapsedDays: Double, label: String = "Weekly") -> UsageWindow {
        let reset = base + (7 - elapsedDays) * 86400
        return UsageWindow(label: label, kind: .weekly, usedPercent: used, resetsAt: reset)
    }
    func advise(used: Double, elapsedDays: Double, _ s: ForecastSettings = settings) -> ModelAdvice {
        let window = weekly(used: used, elapsedDays: elapsedDays)
        let f = Forecaster.forecast(window, samples: [], now: base, calendar: utc)!
        return Forecaster.advice(weekly: f, settings: s, now: base)
    }

    // The cycle average: 20% in 2 days of a 7-day week is 10%/day.
    let f = Forecaster.forecast(weekly(used: 20, elapsedDays: 2), samples: [], now: base, calendar: utc)!
    check(abs(f.avgPerHour * 24 - 10) < 1e-9, "20% over 2 days is 10% per day")
    check(abs(f.left - 80) < 1e-9, "80% left")
    check(abs(f.projectedLeftAtReset(now: base) - 30) < 1e-9, "10%/day for 5 more days leaves 30% at the reset")
    check(f.runsOutIn(now: base) == nil, "it does not run out before the reset at that pace")
    check(!f.learning, "two days is enough to forecast")

    // Advice ladder with Sonnet as the main model (weights 1 : 3 : 5).
    eq(advise(used: 10, elapsedDays: 2).headline, "Opus 5.5 is fine today", "plenty of headroom: Opus is affordable")
    eq(advise(used: 10, elapsedDays: 2).model, .opus, "…and the advised model is Opus")
    eq(advise(used: 20, elapsedDays: 2).headline, "Stay on Sonnet 5.5", "a tighter budget stays on the main model")
    eq(advise(used: 40, elapsedDays: 2).headline, "Use Haiku 5.5 from now on", "little left and many days to go: Haiku")
    eq(advise(used: 40, elapsedDays: 2).tone, .watch, "dropping a model is a watch, not an alarm")
    check(advise(used: 60, elapsedDays: 2).headline.hasPrefix("Go easy"), "not even Haiku lasts: conserve")
    check(advise(used: 60, elapsedDays: 2).detail.count < 60, "…with a line short enough for the card")
    eq(advise(used: 60, elapsedDays: 2).tone, .critical, "…and says so")
    eq(advise(used: 99.9, elapsedDays: 3).headline, "Weekly limit used up", "nothing left is stated plainly")
    eq(advise(used: 1, elapsedDays: 0.5).headline, "Not enough data yet", "half a day is too little to advise anything")
    eq(advise(used: 1, elapsedDays: 0.5).model, nil, "…and no model is named")
    check(advise(used: 1, elapsedDays: 0.5).detail.contains("day"), "…and says what it is waiting for")

    var haikuMain = settings
    haikuMain.baseline = .haiku
    eq(advise(used: 20, elapsedDays: 2, haikuMain).headline, "Stay on Haiku 5.5", "Haiku as the main model is never pushed lower")
    var flat = settings
    flat.weights = [.haiku: 1, .sonnet: 1, .opus: 1]
    eq(advise(used: 20, elapsedDays: 2, flat).headline, "Opus 5.5 is fine today", "equal costs make the top model affordable")
    var versioned = settings
    versioned.version = "6"
    eq(advise(used: 10, elapsedDays: 2, versioned).headline, "Opus 6 is fine today", "the version is editable")

    // Running out before the reset is stated with time.
    let fast = Forecaster.forecast(weekly(used: 70, elapsedDays: 2), samples: [], now: base, calendar: utc)!
    check(fast.runsOutIn(now: base) != nil, "35%/day on 30% left runs out before the reset")
    check(abs((fast.runsOutIn(now: base) ?? 0) / 3600 - 30 / (70.0 / 48)) < 1e-6, "…at left ÷ pace")

    // Hours of nonstop use, scaled by the model's cost against the main model.
    var window = f
    window.left = 50
    window.activePerHour = 5
    check(abs((window.hoursOfUse() ?? 0) - 10) < 1e-9, "50% left at 5%/hour is 10 hours")
    check(abs((window.hoursOfUse(scale: settings.scale(.opus)) ?? 0) - 6) < 1e-9, "Opus uses it 5/3 as fast: 6 hours")
    check(abs((window.hoursOfUse(scale: settings.scale(.haiku)) ?? 0) - 30) < 1e-9, "Haiku uses it a third as fast: 30 hours")
    window.activePerHour = nil
    check(window.hoursOfUse() == nil, "a weekly window with no measured active pace gives no hours")
    window.kind = .session
    window.avgPerHour = 10
    check(abs((window.hoursOfUse() ?? 0) - 5) < 1e-9, "a 5-hour window falls back to its average, which is its active pace")

    // History: one sample per 15 minutes, a new cycle starts over, a falling figure starts over.
    var history = UsageHistory()
    let key = UsageWindow(label: "Weekly", kind: .weekly, usedPercent: 0, resetsAt: base + 86400)
    func reading(_ used: Double, at: Double, reset: Double) -> Reading {
        Reading(windows: [UsageWindow(label: "Weekly", kind: .weekly, usedPercent: used, resetsAt: reset)], fetchedAt: at)
    }
    let t0 = (base / 900).rounded(.down) * 900
    check(history.record(reading(10, at: t0 + 10, reset: base + 86400), provider: .claude, now: t0 + 10), "the first reading is recorded")
    check(!history.record(reading(10, at: t0 + 20, reset: base + 86400), provider: .claude, now: t0 + 20), "an unchanged reading in the same 15 minutes changes nothing")
    check(history.record(reading(11, at: t0 + 30, reset: base + 86400), provider: .claude, now: t0 + 30), "a changed reading in the same 15 minutes replaces it")
    eq(history.samples(.claude, key).count, 1, "…without adding a sample")
    history.record(reading(12, at: t0 + 1000, reset: base + 86400), provider: .claude, now: t0 + 1000)
    eq(history.samples(.claude, key).count, 2, "the next 15 minutes adds a sample")
    history.record(reading(5, at: t0 + 2000, reset: base + 86400), provider: .claude, now: t0 + 2000)
    eq(history.samples(.claude, key).count, 1, "a figure that falls inside one cycle starts the history over")
    history.record(reading(6, at: t0 + 3000, reset: base + 86400 + 7 * 86400), provider: .claude, now: t0 + 3000)
    eq(history.samples(.claude, key).count, 1, "a later reset is a new cycle")
    history.record(reading(7, at: t0 + 3500, reset: base + 86400 + 7 * 86400), provider: .codex, now: t0 + 3500)
    eq(history.samples(.claude, key).count, 1, "providers keep separate histories")
    let reloaded = UsageHistory(data: history.data)
    eq(reloaded.samples(.claude, key), history.samples(.claude, key), "history survives a restart")
    check(!history.record(reading(8, at: t0 + 100, reset: base + 86400), provider: .claude, now: t0 + 3600), "a reading older than a minute is ignored")

    // Interpolation and the active pace: +4% in each of the first four hours, then idle.
    let h0 = (base / 3600).rounded(.down) * 3600
    var samples: [UsageSample] = []
    for i in 0...40 {
        let t = h0 + Double(i) * 900
        samples.append(UsageSample(t: t, used: min(16, Double(i) * 1.0)))
    }
    check(abs((UsageHistory.value(at: h0 + 450, in: samples) ?? -1) - 0.5) < 1e-9, "a value between two readings is interpolated")
    check(UsageHistory.value(at: h0 - 10, in: samples) == nil, "nothing before the first reading")
    var gappy = samples
    gappy.removeSubrange(5...20)
    check(UsageHistory.value(at: h0 + 3600 * 2, in: gappy) == nil, "no value across a long gap in readings")
    let rate = Forecaster.activeRate(samples, kind: .weekly, from: h0, now: h0 + 10 * 3600)
    check(abs((rate ?? -1) - 4) < 1e-9, "four active hours of +4% is 4% per active hour, idle hours ignored")
    check(Forecaster.activeRate(samples, kind: .weekly, from: h0 + 5 * 3600, now: h0 + 9 * 3600) == nil, "no active hour, no pace")

    // Today's use needs a reading from around midnight.
    let midnight = utc.startOfDay(for: Date(timeIntervalSince1970: base)).timeIntervalSince1970
    let overnight = [UsageSample(t: midnight - 600, used: 30), UsageSample(t: midnight + 600, used: 32)]
    let today = Forecaster.forecast(weekly(used: 38, elapsedDays: 2), samples: overnight, now: base, calendar: utc)
    check(abs((today?.usedToday ?? -1) - 7) < 1e-9, "usage since midnight comes from the history around it")
    check(Forecaster.forecast(weekly(used: 38, elapsedDays: 2), samples: [], now: base, calendar: utc)?.usedToday == nil,
          "without history it isn't guessed")

    // Windows that can't be forecast.
    check(Forecaster.forecast(UsageWindow(label: "Weekly (Fable)", kind: .weekly, usedPercent: 5, resetsAt: base + 86400, modelScoped: true),
                              samples: [], now: base) == nil, "model-scoped limits get no forecast")
    check(Forecaster.forecast(UsageWindow(label: "Weekly", kind: .weekly, usedPercent: 50, resetsAt: base - 100), samples: [], now: base) == nil,
          "an expired window gets none")
    check(Forecaster.forecast(weekly(used: 50, elapsedDays: -1), samples: [], now: base) == nil, "a window that hasn't started gets none")
    check(Forecaster.forecast(UsageWindow(label: "x", kind: .other, usedPercent: 5, resetsAt: base + 86400), samples: [], now: base) == nil,
          "a window of unknown length gets none")
    check(Forecaster.forecast(UsageWindow(label: "Weekly", kind: .weekly, usedPercent: .nan, resetsAt: base + 86400), samples: [], now: base) == nil,
          "a non-finite figure gets none")

    // The menu summary: Claude gets advice and hours per model; Codex only the pace.
    let claude = Reading(windows: [
        UsageWindow(label: "5-hour", kind: .session, usedPercent: 30, resetsAt: base + 2 * 3600),
        weekly(used: 10, elapsedDays: 2)], plan: "Max 5x", fetchedAt: base)
    let claudeSummary = Forecaster.summary(provider: .claude, reading: claude, history: UsageHistory(), settings: settings, now: base)
    eq(claudeSummary?.advice?.headline, "Opus 5.5 is fine today", "the summary leads with the advice")
    let text = claudeSummary?.lines.map { $0.text }.joined(separator: "\n") ?? ""
    check(text.contains("Weekly: on track"), "weekly pace is stated")
    check(text.contains("5-hour:"), "the 5-hour pace is stated")
    check(text.contains("5-hour  Haiku") && text.contains("Sonnet") && text.contains("Opus"), "the 5-hour hours are given per model")
    check(text.contains("Weekly  not enough data yet"), "weekly hours without a measured active pace say so, not a guess")
    let young = Reading(windows: [UsageWindow(label: "5-hour", kind: .session, usedPercent: 0.5, resetsAt: base + 5 * 3600 - 300),
                                  weekly(used: 0.5, elapsedDays: 0.1)], fetchedAt: base)
    let youngText = Forecaster.summary(provider: .claude, reading: young, history: UsageHistory(), settings: settings, now: base)?
        .lines.map { $0.text }.joined(separator: "\n") ?? ""
    check(youngText.contains("Not enough data yet") && youngText.contains("5-hour: not enough data yet")
          && youngText.contains("5-hour  not enough data yet"), "a cycle that just began shows no numbers at all")
    check(!youngText.contains("Haiku"), "…and no per-model hours")
    let codex = Forecaster.summary(provider: .codex, reading: claude, history: UsageHistory(), settings: settings, now: base)
    check(codex?.advice == nil, "Codex gets no Claude model advice")
    check(!(codex?.lines.map { $0.text }.joined().contains("Haiku") ?? true), "…and no Claude model names")
    check(Forecaster.summary(provider: .claude, reading: Reading(windows: [], fetchedAt: base), history: UsageHistory(),
                             settings: settings, now: base) == nil, "nothing to forecast, nothing shown")

    // A window of another length (Codex Free reports a 30-day one) is forecast from its own length.
    let month = Reading(windows: [UsageWindow(label: "30-day", kind: .other, usedPercent: 78, resetsAt: base + 20 * 86400, length: 30 * 86400)],
                        fetchedAt: base)
    let monthText = Forecaster.summary(provider: .codex, reading: month, history: UsageHistory(), settings: settings, now: base)?
        .lines.map { $0.text }.joined(separator: "\n") ?? ""
    check(monthText.contains("30-day: runs out in"), "a 30-day window 78% used ten days in runs out before its reset")
    check(Forecaster.summary(provider: .codex, reading: Reading(windows: [UsageWindow(label: "x", kind: .other, usedPercent: 5, resetsAt: base + 86400)],
                                                                fetchedAt: base), history: UsageHistory(), settings: settings, now: base) == nil,
          "an unknown length still gets no forecast")

    // Wording never traps.
    eq(durationText(35 * 60), "35m", "minutes")
    eq(durationText(12000), "3h 20m", "hours and minutes")
    eq(durationText(21 * 3600), "21h", "whole hours past ten")
    eq(durationText(187200), "2d 4h", "days and hours")
    eq(durationText(30), "<1m", "under a minute")
    eq(durationText(.nan), "—", "a non-finite duration")
    eq(durationText(.infinity), "—", "an infinite duration")
    eq(durationText(-5), "<1m", "a negative duration")
    eq(percentText(4), "4.0%", "one decimal below ten")
    eq(percentText(12.4), "12%", "none above ten")
    eq(percentText(.nan), "0%", "a non-finite percent")

    // Settings round trip.
    Cfg.resetAll()
    eq(Cfg.forecastSettings, ForecastSettings(), "defaults: Sonnet 5.5 as the main model, costs 1 : 3 : 5")
    Cfg.mainModel = .opus
    Cfg.modelVersion = " 6 "
    Cfg.setModelWeight(.opus, 8)
    eq(Cfg.forecastSettings.baseline, .opus, "main model is saved")
    eq(Cfg.forecastSettings.version, "6", "version is trimmed")
    eq(Cfg.forecastSettings.weights[.opus], 8, "cost is saved")
    Cfg.setModelWeight(.haiku, -3)
    eq(Cfg.modelWeight(.haiku), 1, "a nonsense cost falls back to the default")
    Cfg.resetAll()
    eq(Cfg.forecastSettings, ForecastSettings(), "Reset to Defaults restores the forecast settings")

    // The card grows to hold the forecast and stays the same without one.
    let state = ProviderState(reading: claude)
    eq(ProviderCardView.height(for: state, forecast: nil), ProviderCardView.height(for: state), "no forecast, same height")
    check(ProviderCardView.height(for: state, forecast: claudeSummary) > ProviderCardView.height(for: state), "the forecast adds height")
}
