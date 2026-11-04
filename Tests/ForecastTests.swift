import AppKit

/// The forecast is an estimate, so the tests pin down the arithmetic and the
/// wording a person acts on: which model is advised, and how many hours remain.
/// The history used here is written by the tests themselves, never real usage.
func runForecastTests(now: Double) {
    Cfg.resetAll()
    let base = (now / 900).rounded(.down) * 900

    func weekly(used: Double, elapsedDays: Double, label: String = "Weekly") -> UsageWindow {
        UsageWindow(label: label, kind: .weekly, usedPercent: used, resetsAt: base + (7 - elapsedDays) * 86400)
    }
    func forecast(_ window: UsageWindow) -> WindowForecast { Forecaster.forecast(window, now: base)! }

    // The cycle average: 20% in 2 days of a 7-day week is 10%/day.
    let f = forecast(weekly(used: 20, elapsedDays: 2))
    check(abs(f.avgPerHour(now: base) * 24 - 10) < 1e-9, "20% over 2 days is 10% per day")
    check(abs(f.left - 80) < 1e-9, "80% left")
    check(abs(f.projectedLeftAtReset(now: base) - 30) < 1e-9, "10%/day for 5 more days leaves 30% at the reset")
    check(f.runsOutIn(now: base) == nil, "it does not run out before the reset at that pace")
    check(!f.learning, "two days is enough to forecast")
    let fast = forecast(weekly(used: 70, elapsedDays: 2))
    check(abs((fast.runsOutIn(now: base) ?? 0) / 3600 - 30 / (70.0 / 48)) < 1e-6, "35%/day on 30% left runs out at left ÷ pace")

    // Windows that can't be forecast.
    check(Forecaster.forecast(UsageWindow(label: "Weekly (Fable)", kind: .weekly, usedPercent: 5, resetsAt: base + 86400, modelScoped: true), now: base) == nil,
          "model-scoped limits get no forecast")
    check(Forecaster.forecast(UsageWindow(label: "Weekly", kind: .weekly, usedPercent: 50, resetsAt: base - 100), now: base) == nil, "an expired window gets none")
    check(Forecaster.forecast(weekly(used: 50, elapsedDays: -1), now: base) == nil, "a window that hasn't started gets none")
    check(Forecaster.forecast(UsageWindow(label: "x", kind: .other, usedPercent: 5, resetsAt: base + 86400), now: base) == nil, "a window of unknown length gets none")
    check(Forecaster.forecast(UsageWindow(label: "Weekly", kind: .weekly, usedPercent: .nan, resetsAt: base + 86400), now: base) == nil, "a non-finite figure gets none")

    // MARK: Prices and the ledger

    let sample = TokenCounts(input: 1000, output: 2000, cacheRead: 1_000_000)
    check(abs(priceOf(modelID: "claude-opus-5-5", longPrompt: false)!.cost(sample) - 0.244) < 1e-9, "Opus 5.5: $4 in, $20 out, $0.20 cache read per MTok")
    check(abs(priceOf(modelID: "claude-sonnet-5-5", longPrompt: false)!.cost(TokenCounts(write5m: 1_000_000)) - 2.5) < 1e-9, "a 5-minute cache write costs 1.25x the input price")
    check(abs(priceOf(modelID: "claude-sonnet-5-5", longPrompt: false)!.cost(TokenCounts(write1h: 1_000_000)) - 4) < 1e-9, "a 1-hour cache write costs 2x")
    check(priceOf(modelID: "claude-opus-4-8", longPrompt: false) != nil, "an older model in the history is priced")
    check(priceOf(modelID: "<synthetic>", longPrompt: false) == nil && priceOf(modelID: "claude-new-9", longPrompt: false) == nil, "an unknown model has no price")
    check(abs(priceOf(modelID: "claude-haiku-5-5", longPrompt: true)!.input - 0.50) < 1e-9, "Haiku 5.5 costs more past a 100K-token prompt")
    eq(familyOf(modelID: "claude-sonnet-5-5"), .sonnet, "model id → family")
    eq(familyOf(modelID: "claude-fable-5"), nil, "Fable isn't one of the three families")

    var ledger = UsageLedger()
    check(!ledger.add(at: base, model: "claude-new-9", tokens: sample), "an unpriced model is left out, never guessed")
    ledger.add(at: base - 100, model: "claude-haiku-5-5", tokens: TokenCounts(input: 200_000))
    let tier = ledger.slice(from: base - 3600, to: base)
    check(abs(tier.actualCost - 0.10) < 1e-9, "a prompt over 100K tokens on Haiku 5.5 is priced at the higher rate")
    check(abs((tier.repriced[.opus] ?? 0) - 0.8) < 1e-9, "…and the same tokens on Opus 5.5 cost 200K × $4")
    check(abs((tier.repriced[.haiku] ?? 0) - 0.10) < 1e-9, "…and on Haiku 5.5 the same")
    eq(tier.activeHours, 1, "one active hour")
    check(UsageLedger().slice(from: base, to: base - 1) == LedgerSlice(), "an empty or inverted range is empty")

    // Ten messages of 1M output tokens over five distinct hours, on one model.
    func work(_ model: String) -> UsageLedger {
        var l = UsageLedger()
        for hour in 1...5 { for _ in 0..<2 { l.add(at: base - Double(hour) * 3600 - 100, model: model, tokens: TokenCounts(output: 1_000_000)) } }
        return l
    }
    let opusWork = work("claude-opus-5-5"), sonnetWork = work("claude-sonnet-5-5")
    let slice = opusWork.slice(from: base - 2 * 86400, to: base)
    check(abs(slice.actualCost - 200) < 1e-9, "10 × 1M output tokens on Opus 5.5 is $200")
    check(abs((slice.repriced[.sonnet] ?? 0) - 100) < 1e-9 && abs((slice.repriced[.haiku] ?? 0) - 5) < 1e-9,
          "the same tokens cost $100 on Sonnet 5.5 and $5 on Haiku 5.5")
    eq(slice.activeHours, 5, "five active hours")

    // MARK: Projection — calibrated against the reported percentage

    let twoDays = forecast(weekly(used: 20, elapsedDays: 2))
    let opusP = Forecaster.project(twoDays, ledger: opusWork, now: base)!
    // 20% reported ↔ $200 of work: 0.1% per dollar.
    check(abs(opusP.estimate(.opus)!.pctPerDay - 10) < 1e-9, "Opus: $200 over 2 days at 0.1%/$ is 10%/day")
    check(abs(opusP.estimate(.sonnet)!.pctPerDay - 5) < 1e-9, "the same work on Sonnet is half: 5%/day")
    check(abs(opusP.estimate(.haiku)!.pctPerDay - 0.25) < 1e-9, "…and on Haiku 0.25%/day")
    check(abs((opusP.estimate(.opus)!.hoursLeft ?? 0) - 20) < 1e-9, "80% left at 4%/active hour on Opus is 20 hours")
    check(abs((opusP.estimate(.sonnet)!.hoursLeft ?? 0) - 40) < 1e-9, "…40 on Sonnet")
    check(abs((opusP.estimate(.haiku)!.hoursLeft ?? 0) - 800) < 1e-9, "…800 on Haiku")
    eq(opusP.dominant, .opus, "the family that did the work is the dominant one")
    check(Forecaster.project(twoDays, ledger: UsageLedger(), now: base) == nil, "no history, no projection")
    check(Forecaster.project(forecast(weekly(used: 1, elapsedDays: 0.5)), ledger: opusWork, now: base) == nil, "half a day in: too early to project")
    check(Forecaster.project(forecast(weekly(used: 1.5, elapsedDays: 3)), ledger: opusWork, now: base) == nil, "under 2% used: too little to calibrate")
    var tiny = UsageLedger()
    tiny.add(at: base - 3600, model: "claude-opus-5-5", tokens: TokenCounts(output: 1000))
    check(Forecaster.project(twoDays, ledger: tiny, now: base) == nil, "under $1 of recorded work can't calibrate 20%")
    var oneHour = UsageLedger()
    oneHour.add(at: base - 3600, model: "claude-opus-5-5", tokens: TokenCounts(output: 1_000_000))
    check(Forecaster.project(twoDays, ledger: oneHour, now: base)!.estimate(.opus)!.hoursLeft == nil, "one active hour isn't a measured pace: no hours")

    // MARK: Advice

    func advise(used: Double, elapsedDays: Double, _ ledger: UsageLedger?) -> ModelAdvice {
        let window = forecast(weekly(used: used, elapsedDays: elapsedDays))
        return Forecaster.advice(weekly: window, projection: ledger.flatMap { Forecaster.project(window, ledger: $0, now: base) }, now: base)
    }
    eq(advise(used: 10, elapsedDays: 2, sonnetWork).headline, "Opus 5.5 is fine today", "Sonnet is doing the work and Opus is affordable")
    eq(advise(used: 10, elapsedDays: 2, sonnetWork).model, .opus, "…the advised model is Opus")
    eq(advise(used: 10, elapsedDays: 2, sonnetWork).tone, .good, "…and it's good news")
    eq(advise(used: 20, elapsedDays: 2, sonnetWork).headline, "Stay on Sonnet 5.5", "a tighter budget stays on the model doing the work")
    eq(advise(used: 40, elapsedDays: 2, sonnetWork).headline, "Use Haiku 5.5 from now on", "little left and many days to go: Haiku")
    eq(advise(used: 40, elapsedDays: 2, sonnetWork).tone, .watch, "dropping a model is a watch, not an alarm")
    check(advise(used: 95, elapsedDays: 2, sonnetWork).headline.hasPrefix("Go easy"), "not even Haiku lasts: conserve")
    eq(advise(used: 95, elapsedDays: 2, sonnetWork).tone, .critical, "…and says so")
    check(advise(used: 40, elapsedDays: 2, sonnetWork).detail.contains("Can spend ≈12%/day") && advise(used: 40, elapsedDays: 2, sonnetWork).detail.contains("Haiku pace ≈1.0%/day"),
          "the line gives the budget and the pace on the advised model")
    check(advise(used: 40, elapsedDays: 2, sonnetWork).detail.count < 70, "…and fits the card")
    eq(advise(used: 99.9, elapsedDays: 3, sonnetWork).headline, "Weekly limit used up", "nothing left is stated plainly")
    eq(advise(used: 1, elapsedDays: 0.5, sonnetWork).headline, "Not enough data yet", "half a day is too little to advise anything")
    eq(advise(used: 1, elapsedDays: 0.5, sonnetWork).model, nil, "…and no model is named")
    eq(advise(used: 20, elapsedDays: 2, nil).headline, "Not enough data yet", "no Claude Code history: not enough data")
    check(advise(used: 20, elapsedDays: 2, nil).detail.contains("Claude Code"), "…and says what is missing")

    // MARK: Summary

    let claude = Reading(windows: [weekly(used: 10, elapsedDays: 2)], plan: "Max 20x", fetchedAt: base)
    let withHistory = Forecaster.summary(provider: .claude, reading: claude, ledger: sonnetWork, now: base)
    eq(withHistory?.advice?.headline, "Opus 5.5 is fine today", "the summary leads with the advice")
    let text = withHistory?.lines.map { $0.text }.joined(separator: "\n") ?? ""
    check(text.contains("Weekly: on track"), "weekly pace is stated")
    check(text.contains("Weekly · pace and hours of use left"), "the per-model block is introduced")
    for model in ModelFamily.allCases { check(text.contains(model.title), "\(model.title) has its own row") }
    check(text.contains("Sonnet 5.5 ≈5.0%/day") && text.contains("Opus 5.5   ≈10%/day"), "a row gives the pace per day, in aligned columns")
    check(text.contains("left"), "…and the hours of use left")
    let rows = withHistory?.lines.filter { $0.style == .model }.map { $0.text.count } ?? []
    check(rows.count == 3 && rows.allSatisfy { $0 < 40 }, "three model rows, short enough for the card")
    let without = Forecaster.summary(provider: .claude, reading: claude, ledger: nil, now: base)
    let withoutText = without?.lines.map { $0.text }.joined(separator: "\n") ?? ""
    check(withoutText.contains("Weekly per model: not enough data yet") && !withoutText.contains("Haiku"), "without history the model rows say so, with no numbers")
    let codex = Forecaster.summary(provider: .codex, reading: claude, ledger: sonnetWork, now: base)
    check(codex?.advice == nil && !(codex?.lines.map { $0.text }.joined().contains("Haiku") ?? true), "Codex gets no Claude model advice")
    let month = Reading(windows: [UsageWindow(label: "30-day", kind: .other, usedPercent: 78, resetsAt: base + 20 * 86400, length: 30 * 86400)], fetchedAt: base)
    check(Forecaster.summary(provider: .codex, reading: month, ledger: nil, now: base)?.lines.map { $0.text }.joined().contains("30-day: runs out in") == true,
          "a 30-day window 78% used ten days in runs out before its reset")
    check(Forecaster.summary(provider: .claude, reading: Reading(windows: [], fetchedAt: base), ledger: nil, now: base) == nil, "nothing to forecast, nothing shown")
    let young = Reading(windows: [UsageWindow(label: "5-hour", kind: .session, usedPercent: 0.5, resetsAt: base + 5 * 3600 - 300), weekly(used: 0.5, elapsedDays: 0.1)], fetchedAt: base)
    let youngText = Forecaster.summary(provider: .claude, reading: young, ledger: sonnetWork, now: base)?.lines.map { $0.text }.joined(separator: "\n") ?? ""
    check(youngText.contains("Not enough data yet") && youngText.contains("5-hour: not enough data yet") && !youngText.contains("Haiku"),
          "a cycle that just began shows no numbers at all")
    // Gated by the setting, and only for a current reading.
    let current = ProviderState(reading: claude)
    check(Forecaster.summary(provider: .claude, state: current, ledger: sonnetWork, now: base) != nil, "a current reading is forecast")
    Cfg.forecastEnabled = false
    check(Forecaster.summary(provider: .claude, state: current, ledger: sonnetWork, now: base) == nil, "turned off in Settings: nothing")
    Cfg.resetAll()
    check(Forecaster.summary(provider: .claude, state: ProviderState(reading: claude, restored: true), ledger: sonnetWork, now: base) == nil,
          "a restored reading isn't projected forward")

    // MARK: Reading Claude Code's files

    let real = nowEpoch()
    let root = NSTemporaryDirectory() + "aicb-ledger-\(UUID().uuidString)"
    let nested = root + "/project-a/sub"
    try? FileManager.default.createDirectory(atPath: nested, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: root) }
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    func line(_ id: String, _ model: String, _ at: Double, output: Int = 1_000_000, type: String = "assistant", trailing: String = "\n") -> String {
        "{\"type\":\"\(type)\",\"timestamp\":\"\(iso.string(from: Date(timeIntervalSince1970: at)))\",\"message\":{\"model\":\"\(model)\",\"id\":\"\(id)\","
            + "\"usage\":{\"input_tokens\":0,\"output_tokens\":\(output),\"cache_read_input_tokens\":0,\"cache_creation_input_tokens\":0}}}" + trailing
    }
    func append(_ text: String, to path: String) {
        if let handle = FileHandle(forWritingAtPath: path) { handle.seekToEndOfFile(); handle.write(Data(text.utf8)); try? handle.close() }
        else { try? text.write(toFile: path, atomically: true, encoding: .utf8) }
    }
    let file = nested + "/session.jsonl"
    append(line("A", "claude-opus-5-5", real - 600) + line("A", "claude-opus-5-5", real - 600)            // one message, written twice
           + line("B", "claude-sonnet-5-5", real - 500) + line("U", "claude-opus-5-5", real - 400, type: "user")
           + line("OLD", "claude-opus-5-5", real - 20 * 86400) + line("X", "claude-new-9", real - 300)
           + line("S", "<synthetic>", real - 200), to: file)
    var scanned = UsageLedger()
    check(scanned.scan(root: root, now: real), "the first scan reads the file")
    var cost = scanned.slice(from: real - 3600, to: real + 1).actualCost
    check(abs(cost - 30) < 1e-9, "a message written twice counts once; user lines, old, unknown and synthetic ones don't ($20 Opus + $10 Sonnet)")
    check(!scanned.scan(root: root, now: real), "a scan with nothing new changes nothing")
    append(line("C", "claude-opus-5-5", real - 100) + line("C", "claude-opus-5-5", real - 100), to: file)
    scanned.scan(root: root, now: real)
    cost = scanned.slice(from: real - 3600, to: real + 1).actualCost
    check(abs(cost - 50) < 1e-9, "only what was appended is read, and a duplicate across scans counts once")
    let partial = line("D", "claude-opus-5-5", real - 50, trailing: "")
    append(String(partial.prefix(60)), to: file)
    scanned.scan(root: root, now: real)
    check(abs(scanned.slice(from: real - 3600, to: real + 1).actualCost - 50) < 1e-9, "a line still being written isn't read")
    append(String(partial.dropFirst(60)) + "\n", to: file)
    scanned.scan(root: root, now: real)
    check(abs(scanned.slice(from: real - 3600, to: real + 1).actualCost - 70) < 1e-9, "…until it is complete")
    // Another field order is still parsed, and still counted once.
    let reordered = "{\"type\":\"assistant\",\"timestamp\":\"\(iso.string(from: Date(timeIntervalSince1970: real - 40)))\",\"message\":{\"id\":\"F\",\"model\":\"claude-sonnet-5-5\","
        + "\"usage\":{\"input_tokens\":0,\"output_tokens\":1000000,\"cache_read_input_tokens\":0,\"cache_creation_input_tokens\":0}}}\n"
    append(reordered + reordered, to: file)
    scanned.scan(root: root, now: real)
    check(abs(scanned.slice(from: real - 3600, to: real + 1).actualCost - 80) < 1e-9, "a message with another field order counts once ($10 Sonnet)")
    // A week is all that is kept.
    var weekOld = UsageLedger()
    weekOld.add(at: real - 7.5 * 86400, model: "claude-opus-5-5", tokens: TokenCounts(output: 1_000_000))
    weekOld.add(at: real - 6.5 * 86400, model: "claude-opus-5-5", tokens: TokenCounts(output: 1_000_000))
    try? FileManager.default.createDirectory(atPath: root + "/empty", withIntermediateDirectories: true)
    weekOld.scan(root: root + "/empty", now: real)
    check(abs(weekOld.slice(from: real - 8 * 86400, to: real).actualCost - 20) < 1e-9, "a scan drops what is older than seven days and keeps the rest")
    let stale = nested + "/stale.jsonl"
    append(line("Z", "claude-opus-5-5", real - 60), to: stale)
    try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: real - 20 * 86400)], ofItemAtPath: stale)
    var other = UsageLedger()
    other.scan(root: root, now: real)
    check(abs(other.slice(from: real - 3600, to: real + 1).actualCost - 80) < 1e-9, "a file untouched for 20 days isn't read")
    var nothing = UsageLedger()
    check(!nothing.scan(root: root + "/missing", now: real), "a missing folder is fine")
    try? FileManager.default.removeItem(atPath: file)
    scanned.scan(root: root, now: real)
    check(scanned.files[file] == nil, "a deleted file is forgotten")

    // The store keeps it across a restart, and can forget it.
    let stateFile = URL(fileURLWithPath: root + "/state/usage-ledger.json")
    let store = LedgerStore(root: root, file: stateFile)
    append(line("E", "claude-opus-5-5", real - 30), to: file)
    var finished = false
    store.refresh(minimumGap: 0) { finished = true }
    let deadline = Date().addingTimeInterval(15)
    while !finished && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    check(finished && abs(store.snapshot.slice(from: real - 3600, to: nowEpoch() + 1).actualCost - 20) < 1e-9, "the store scans in the background")
    check(FileManager.default.fileExists(atPath: stateFile.path), "…and saves what it read")
    let reopened = LedgerStore(root: root, file: stateFile)
    eq(reopened.snapshot.buckets, store.snapshot.buckets, "a restart keeps it without rescanning")
    reopened.clear()
    check(reopened.snapshot.isEmpty && !FileManager.default.fileExists(atPath: stateFile.path), "clearing forgets it, in memory and on disk")

    // MARK: Checking forecasts against what happened

    func readings(_ used: (Double) -> Double, hours: Int, provider: Provider = .claude, reset: Double? = nil) -> SampleLog {
        var l = SampleLog()
        for h in 0...hours {
            let t = base + Double(h) * 3600
            l.record(Reading(windows: [UsageWindow(label: "Weekly", kind: .weekly, usedPercent: min(100, used(Double(h))), resetsAt: reset ?? base + 7 * 86400)], fetchedAt: t),
                     provider: provider, now: t)
        }
        return l
    }
    let now3d = base + 72 * 3600
    // Steady use: the average-pace forecast 24 hours ahead is exactly right.
    let steady = Accuracy.report(readings({ $0 * 10 / 24 }, hours: 72), provider: .claude, kind: .weekly, ledger: nil, now: now3d)
    check(steady.hasPace && steady.paceChecks == 25, "a day to learn, a day to look ahead: 25 hourly checks in three days")
    check(abs(steady.paceMissPoints) < 1e-9 && abs(steady.paceBiasPoints) < 1e-9, "steady use: the 24-hour forecast misses by nothing")
    // Use that speeds up: the average-pace forecast runs low.
    let speeding = Accuracy.report(readings({ ($0 / 24) * ($0 / 24) * 5 }, hours: 72), provider: .claude, kind: .weekly, ledger: nil, now: now3d)
    check(speeding.paceMissPoints > 2 && speeding.paceBiasPoints < -2, "use that speeds up: the forecast misses by points and runs low")
    check(!Accuracy.report(readings({ $0 * 10 / 24 }, hours: 40), provider: .claude, kind: .weekly, ledger: nil, now: base + 40 * 3600).hasPace,
          "less than two days of readings: no pace check yet")
    check(Accuracy.report(readings({ $0 * 10 / 24 }, hours: 72), provider: .codex, kind: .weekly, ledger: nil, now: now3d).paceChecks == 0, "another provider's readings aren't mixed in")

    // The model-cost check: the same dollars always use the same %, or they don't.
    func spending(second: Int) -> UsageLedger {
        var l = UsageLedger()
        for k in 1...72 { l.add(at: base + Double(k) * 3600 - 60, model: "claude-opus-5-5", tokens: TokenCounts(output: k > 36 ? second : 100_000)) }
        return l
    }
    let proportional = Accuracy.report(readings({ $0 }, hours: 72), provider: .claude, kind: .weekly, ledger: spending(second: 100_000), now: now3d)
    check(proportional.hasCost && abs(proportional.costRatio - 1) < 0.01, "% proportional to the priced tokens: real burn ×1.00 of priced")
    let doubled = Accuracy.report(readings({ $0 }, hours: 72), provider: .claude, kind: .weekly, ledger: spending(second: 200_000), now: now3d)
    check(doubled.costRatio < 0.9, "dollars doubled but the % didn't: the priced tokens over-predicted, ratio below 1")
    check(Accuracy.report(readings({ $0 }, hours: 72), provider: .codex, kind: .weekly, ledger: spending(second: 100_000), now: now3d).costChecks == 0,
          "the model-cost check is Claude's alone")
    check(Accuracy.report(readings({ $0 }, hours: 72), provider: .claude, kind: .weekly, ledger: nil, now: now3d).costChecks == 0, "no history, no cost check")

    // What the card says.
    let sayings = Accuracy.lines(readings({ $0 * 10 / 24 }, hours: 72), provider: .claude, kind: .weekly, ledger: spending(second: 100_000), now: now3d).map { $0.text }.joined(separator: "\n")
    check(sayings.contains("24h pace: off by 0.0 pts · 25 checks"), "the pace line gives the miss and the number of checks")
    check(sayings.contains("Model costs: real burn ×"), "the cost line gives the ratio")
    eq(Accuracy.lines(readings({ $0 * 10 / 24 }, hours: 30), provider: .claude, kind: .weekly, ledger: nil, now: base + 30 * 3600).map { $0.text }, ["Accuracy check: not enough data yet"],
       "too few checks: it says so instead of showing a number")
    eq(Accuracy.lines(nil, provider: .claude, kind: .weekly, ledger: nil, now: now3d).count, 0, "no log, no lines")
    let withLog = Forecaster.summary(provider: .claude, reading: claude, ledger: sonnetWork, samples: readings({ $0 * 10 / 24 }, hours: 72), now: base)
    check(withLog?.lines.contains { $0.text == "Checked against what happened" } == true, "the summary carries the accuracy check")

    // Keeping the readings.
    var kept = SampleLog()
    func one(_ used: Double, at: Double, reset: Double = base + 7 * 86400) -> Reading {
        Reading(windows: [UsageWindow(label: "Weekly", kind: .weekly, usedPercent: used, resetsAt: reset)], fetchedAt: at)
    }
    check(kept.record(one(10, at: base + 10), provider: .claude, now: base + 10), "the first reading is kept")
    check(!kept.record(one(10, at: base + 20), provider: .claude, now: base + 20), "an unchanged figure in the same 15 minutes changes nothing")
    check(kept.record(one(11, at: base + 30), provider: .claude, now: base + 30), "a changed figure replaces it")
    kept.record(one(12, at: base + 1000, reset: base + 7 * 86400 + 0.012), provider: .claude, now: base + 1000)
    eq(kept.series.count, 1, "a reset time that jitters by milliseconds is the same cycle")
    eq(kept.series.values.first?.points.count, 2, "the next 15 minutes adds a point")
    check(!kept.record(one(13, at: base + 100), provider: .claude, now: base + 3600), "a reading older than a minute is ignored")
    check(!kept.record(Reading(windows: [UsageWindow(label: "Weekly (Fable)", kind: .weekly, usedPercent: 5, resetsAt: base + 86400, modelScoped: true)], fetchedAt: base + 2000),
                       provider: .claude, now: base + 2000), "a model-scoped limit isn't logged")
    eq(SampleLog(data: kept.data).series, kept.series, "the log survives a restart")
    kept.record(one(5, at: base + 15 * 86400, reset: base + 22 * 86400), provider: .claude, now: base + 15 * 86400)
    eq(kept.series.count, 1, "a cycle that ended more than a week ago is dropped")

    // MARK: Wording and settings

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

    Cfg.resetAll()
    check(Cfg.forecastEnabled && Cfg.useClaudeHistory, "forecast and the local history are on by default")
    Cfg.useClaudeHistory = false
    check(!Cfg.useClaudeHistory, "the local history can be turned off")
    Cfg.resetAll()
    check(Cfg.useClaudeHistory, "Reset to Defaults turns it back on")

    // The card grows to hold the forecast and stays the same without one.
    let state = ProviderState(reading: claude)
    eq(ProviderCardView.height(for: state, forecast: nil), ProviderCardView.height(for: state), "no forecast, same height")
    check(ProviderCardView.height(for: state, forecast: withHistory) > ProviderCardView.height(for: state), "the forecast adds height")
}
