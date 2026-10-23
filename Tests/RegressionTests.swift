import AppKit

/// HTTP failures are exercised through URLSession without any real service or login.
private final class StubProtocol: URLProtocol {
    static let cancelled = LockedValue<Bool>()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        if path == "/timeout" { return }
        if path == "/offline" {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return
        }
        if path == "/tls" {
            client?.urlProtocol(self, didFailWithError: URLError(.secureConnectionFailed)); return
        }
        let status = Int(path.dropFirst()) ?? 200
        let body = request.value(forHTTPHeaderField: "X-Test") ?? "fixture"
        let reply = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: reply, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { Self.cancelled.store(true) }
}

func runRegressionTests(now: Double) {
    Cfg.resetAll()
    let lockDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("aicb-lock-\(UUID().uuidString)")
    let lockPath = lockDirectory.appendingPathComponent("instance.lock").path
    var owner = try! AppInstance.acquire(at: lockPath)
    check(owner != nil, "first process acquires the instance lock")
    check(try! AppInstance.acquire(at: lockPath) == nil, "second independent file description cannot acquire the same lock")
    owner = nil
    var successor = try! AppInstance.acquire(at: lockPath)
    check(successor != nil, "normal exit releases the instance lock for the next launch")
    successor = nil
    try? FileManager.default.removeItem(at: lockDirectory)
    func sample(_ used: Double, _ at: Double, reset: Double? = nil, label: String = "5-hour", scoped: Bool = false) -> Reading {
        Reading(windows: [UsageWindow(label: label, kind: .session, usedPercent: used, resetsAt: reset, modelScoped: scoped)], fetchedAt: at)
    }
    func observe(_ tracker: inout QuotaAlertTracker, _ value: Reading, provider: Provider = .codex,
                 low: Bool = true, recovery: Bool = true, at: Double? = nil) -> [QuotaAlert] {
        tracker.observe(value, provider: provider, now: at ?? value.fetchedAt, lowEnabled: low, recoveryEnabled: recovery)
    }

    // Exact threshold, durable deduplication and genuine reset transitions.
    var tracker = QuotaAlertTracker()
    eq(observe(&tracker, sample(79.6, now, reset: now + 600)).count, 0, "20.4% remaining is not a 20% alert")
    let low = observe(&tracker, sample(80, now + 1, reset: now + 600))
    eq(low.map { $0.kind }, [.low], "exactly 20% remaining alerts")
    eq(low.first?.left, 20, "alert carries the provider's remaining amount")
    low.forEach { tracker.acknowledge($0) }
    for (offset, used) in [81.0, 79, 90, 100].enumerated() {
        eq(observe(&tracker, sample(used, now + Double(offset + 2), reset: now + 600)).count, 0,
           "one low alert per window despite further use or threshold oscillation")
    }
    tracker = QuotaAlertTracker(data: tracker.data)
    eq(observe(&tracker, sample(100, now + 10, reset: now + 600)).count, 0, "restart preserves deduplication")
    eq(observe(&tracker, sample(0, now + 601, reset: now + 600)).count, 0, "an expired response cannot announce recovery")
    let recovered = observe(&tracker, sample(5, now + 602, reset: now + 18600))
    eq(recovered.map { $0.kind }, [.recovered], "new official window confirms recovery")
    eq(recovered.first?.left, 95, "recovery does not invent 100%")
    recovered.forEach { tracker.acknowledge($0) }
    eq(observe(&tracker, sample(6, now + 603, reset: now + 18600)).count, 0, "recovery is not repeated")
    let lowNext = observe(&tracker, sample(85, now + 604, reset: now + 18600))
    eq(lowNext.map { $0.kind }, [.low], "next window can warn again")
    check(lowNext.first?.id != low.first?.id, "different windows have different delivery IDs")

    // Delivery is acknowledged only after successful scheduling; both alert types can retry.
    var retry = QuotaAlertTracker()
    let first = observe(&retry, sample(90, now, reset: now + 60))
    eq(observe(&retry, sample(91, now + 1, reset: now + 60)).first?.id, first.first?.id, "a failed low alert retries with a stable ID")
    first.forEach { retry.acknowledge($0) }
    let refill = observe(&retry, sample(0, now + 61, reset: now + 600))
    retry = QuotaAlertTracker(data: retry.data)
    eq(observe(&retry, sample(1, now + 62, reset: now + 600)).first?.id, refill.first?.id, "failed recovery survives a restart and retries")
    refill.forEach { retry.acknowledge($0) }
    eq(observe(&retry, sample(1, now + 63, reset: now + 600)).count, 0, "successful recovery consumes retry")
    var consumedAgain = QuotaAlertTracker()
    _ = observe(&consumedAgain, sample(100, now))
    _ = observe(&consumedAgain, sample(10, now + 1))
    eq(observe(&consumedAgain, sample(100, now + 2)).filter { $0.kind == .recovered }.count, 0,
       "a failed recovery alert is dropped if quota is already exhausted again")

    var late = QuotaAlertTracker()
    let obsolete = observe(&late, sample(90, now, reset: now + 60))
    let newLow = observe(&late, sample(95, now + 61, reset: now + 600))
    obsolete.forEach { late.acknowledge($0) }
    eq(observe(&late, sample(96, now + 62, reset: now + 600)).first?.id, newLow.first?.id, "late acknowledgment cannot consume next cycle's alert")

    // Stale, future, reordered and malformed input never creates an alert.
    var invalid = QuotaAlertTracker()
    eq(observe(&invalid, sample(95, now), at: now + 61).count, 0, "old snapshots do not alert")
    eq(observe(&invalid, sample(95, now + 6), at: now).count, 0, "future snapshots do not alert")
    for bad in [Double.nan, .infinity, -1, 101] {
        eq(observe(&invalid, sample(bad, now)).count, 0, "invalid percentage does not alert")
    }
    _ = observe(&invalid, sample(95, now, reset: now + 600))
    eq(observe(&invalid, sample(0, now - 1, reset: now + 600)).count, 0, "out-of-order reading cannot announce recovery")
    eq(observe(&invalid, sample(95, now, reset: now + 600)).count, 0, "same reading is not processed twice")
    eq(QuotaAlertTracker(data: Data("broken".utf8)).checkpoints.count, 0, "corrupt notification history recovers safely")

    var permissions = QuotaAlertTracker()
    eq(observe(&permissions, sample(90, now), low: false, recovery: false).count, 0, "disabled notifications stay silent")
    eq(observe(&permissions, sample(91, now + 1)).map { $0.kind }, [.low], "permission granted later allows a current low alert")
    var disabledRecovery = QuotaAlertTracker()
    _ = observe(&disabledRecovery, sample(100, now, reset: now + 60))
    eq(observe(&disabledRecovery, sample(0, now + 61, reset: now + 600), recovery: false).count, 0, "recovery toggle is respected")
    eq(observe(&disabledRecovery, sample(1, now + 62, reset: now + 600)).count, 0, "re-enabling does not replay an old recovery")

    var multi = QuotaAlertTracker()
    var multiReading = sample(85, now, reset: now + 600)
    multiReading.windows.append(UsageWindow(label: "Weekly", kind: .weekly, usedPercent: 90, resetsAt: now + 3600))
    multiReading.windows.append(UsageWindow(label: "Weekly (model)", kind: .weekly, usedPercent: 95, resetsAt: now + 3600, modelScoped: true))
    let multiLow = observe(&multi, multiReading)
    eq(multiLow.count, 3, "each limit including per-model limits is covered")
    multiLow.forEach { multi.acknowledge($0) }
    eq(observe(&multi, sample(85, now), provider: .claude).count, 1, "providers have independent notification history")
    _ = observe(&multi, sample(86, now + 1, reset: now + 600))
    eq(multi.checkpoints.count, 2, "removed windows are pruned without deleting the other provider")
    var duplicate = sample(85, now)
    duplicate.windows.append(duplicate.windows[0])
    var duplicates = QuotaAlertTracker()
    eq(observe(&duplicates, duplicate).count, 1, "duplicate window entries cannot duplicate a banner")

    var jitter = QuotaAlertTracker()
    _ = observe(&jitter, sample(90, now, reset: now + 600))
    eq(observe(&jitter, sample(85, now + 1, reset: now + 601)).filter { $0.kind == .recovered }.count, 0, "a reset-time correction is not quota recovery")
    var exhausted = QuotaAlertTracker()
    _ = observe(&exhausted, sample(100, now))
    eq(observe(&exhausted, sample(30, now + 1)).filter { $0.kind == .recovered }.count, 1, "exhausted quota becoming available is a recovery without a reset timestamp")

    // Long deterministic sequences exercise checkpoint boundedness and deduplication.
    var soak = QuotaAlertTracker(), lowCount = 0, recoveryCount = 0
    for cycle in 0..<100 {
        for step in 0..<101 {
            let at = now + Double(cycle * 102 + step)
            let alerts = observe(&soak, sample(Double(step), at, reset: now + Double(cycle * 102 + 101)))
            lowCount += alerts.filter { $0.kind == .low }.count
            recoveryCount += alerts.filter { $0.kind == .recovered }.count
            alerts.forEach { soak.acknowledge($0) }
        }
    }
    eq(lowCount, 100, "10,100 readings produce one low alert per cycle")
    eq(recoveryCount, 99, "10,100 readings produce one recovery per observed reset")
    eq(soak.checkpoints.count, 1, "notification history remains bounded during a long run")
    check((soak.data?.count ?? 10000) < 512, "one window uses less than 512 bytes of persisted history")

    // Display scheduling: no tick timer when closed, and no earlier redraw than needed.
    let fresh = ProviderState(reading: sample(50, now, reset: now + 5000))
    approx(nextDisplayChange([fresh], now: now + 2, menuOpen: false), now + 660.01, "closed menu waits for stale boundary")
    approx(nextDisplayChange([fresh], now: now + 2, menuOpen: true), now + 20.01, "open menu updates at next countdown change")
    let nearReset = ProviderState(reading: sample(50, now, reset: now + 50))
    approx(nextDisplayChange([nearReset], now: now + 2, menuOpen: false), now + 50.01, "reset expiry updates even while menu closed")
    eq(nextDisplayChange([], now: now, menuOpen: false), nil, "no providers means no display timer")
    let old = ProviderState(reading: sample(50, now - 1000))
    eq(nextDisplayChange([old], now: now, menuOpen: false), nil, "stale data without resets has no background redraw")
    approx(nextDisplayChange([old], now: now, menuOpen: true), now + 20.01, "visible old reading updates at next age boundary")
    check((nextDisplayChange([fresh], now: now + 20, menuOpen: true) ?? 0) > now + 20, "exact countdown boundary cannot spin a zero-delay timer")
    var restored = ProviderState(reading: sample(30, now), restored: true)
    check(!restored.isCurrent(now: now), "restored snapshots remain faded even if recently saved")
    eq(nextDisplayChange([restored], now: now, menuOpen: false), nil, "restored snapshot has no redundant stale timer")
    restored.record(.success(sample(30, now + 1)))
    check(restored.isCurrent(now: now + 1), "successful refresh makes restored data current")
    check(!ProviderState(reading: sample(30, now + 100)).isCurrent(now: now), "clock skew cannot mark far-future data current")
    check(!ProviderState(reading: sample(30, .nan)).isCurrent(now: now), "non-finite timestamp cannot be current")

    // JSON booleans cannot silently become 0% or 1% usage.
    eq(number(true), nil, "JSON true is not a usage number")
    eq(number(false), nil, "JSON false is not a usage number")
    eq(number("nan"), nil, "non-finite numeric string rejected")
    eq(number("91.25"), 91.25, "numeric string remains supported")
    throwsError({ try parseCodexUsage(Data(#"{"rate_limit":{"primary_window":{"used_percent":true}}}"#.utf8), now: now) }, "boolean Codex percentage is rejected")
    throwsError({ try parseClaudeUsage(Data(#"{"limits":[{"kind":"session","percent":false}]}"#.utf8), plan: nil, now: now) }, "boolean Claude percentage is rejected")

    // Session-level timeout and cancellation, offline/TLS errors, bodies and HTTP status.
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubProtocol.self]
    let session = URLSession(configuration: config)
    let response = try? httpGet("https://usage.invalid/200", headers: ["X-Test": "passed"], using: session)
    eq(response?.status, 200, "HTTP status is preserved")
    eq(response.map { String(decoding: $0.body, as: UTF8.self) }, "passed", "HTTP request headers and reply body survive")
    for status in [401, 403, 429, 500, 503] {
        eq(try? httpGet("https://usage.invalid/\(status)", headers: [:], using: session).status, status, "non-200 status reaches provider error handling")
    }
    throwsError({ try httpGet("https://usage.invalid/offline", headers: [:], using: session) }, "offline error is surfaced")
    throwsError({ try httpGet("https://usage.invalid/tls", headers: [:], using: session) }, "TLS failure is surfaced")
    let started = ProcessInfo.processInfo.systemUptime
    throwsError({ try httpGet("https://usage.invalid/timeout", headers: [:], using: session, timeout: 0.05) }, "stalled request has a bounded wait")
    check(ProcessInfo.processInfo.systemUptime - started < 1, "HTTP timeout doesn't block for the default 32 seconds")
    pump(until: { StubProtocol.cancelled.load() == true })
    eq(StubProtocol.cancelled.load(), true, "timeout cancels the underlying URLSession task")
    session.invalidateAndCancel()

    // Deterministic 429 ladder, cap, successful reset, and provider-specific gaps.
    var clock = 1000.0, count = 0, shouldFail = true
    let backoff = RefreshController(sources: [.init(provider: .codex, fetch: {
        if shouldFail { throw UsageError("rate limited", rateLimited: true) }
        return sample(30, now)
    })], clock: { clock })
    backoff.onResult = { _, _ in count += 1 }
    for (index, delay) in [300.0, 600, 1200, 1800, 1800].enumerated() {
        backoff.refresh(); pump(until: { count == index + 1 })
        eq(count, index + 1, "429 attempt delivered")
        clock += delay - 1
        backoff.refresh()
        pump(until: { false }, timeout: 0.02)
        eq(count, index + 1, "429 backoff lasts for the complete \(Int(delay)) seconds")
        clock += 1
    }
    shouldFail = false
    backoff.refresh(); pump(until: { count == 6 })
    shouldFail = true; clock += 1
    backoff.refresh(); pump(until: { count == 7 })
    clock += 300
    backoff.refresh(); pump(until: { count == 8 })
    eq(count, 8, "success resets exponential backoff to five minutes")

    var seen: [Provider] = []
    let selective = RefreshController(sources: [.init(provider: .codex, fetch: { sample(30, now) }),
                                               .init(provider: .claude, fetch: { sample(40, now) })], clock: { clock })
    selective.onResult = { p, _ in seen.append(p) }
    selective.refresh(providers: [.codex]); pump(until: { seen.count == 1 })
    selective.refresh(minimumGap: 120); pump(until: { seen.count == 2 })
    eq(seen, [.codex, .claude], "recent Codex refresh does not suppress Claude")
    var ticks = 0
    let stopped = RefreshController(sources: [.init(provider: .codex, fetch: { sample(30, now) })])
    stopped.onResult = { _, _ in ticks += 1 }
    stopped.start(every: 0.03, refreshImmediately: false)
    pump(until: { ticks >= 2 }); stopped.stop()
    pump(until: { false }, timeout: 0.05)
    let stoppedCount = ticks
    pump(until: { false }, timeout: 0.1)
    eq(ticks, stoppedCount, "stop invalidates the repeating refresh timer")
    stopped.isEnabled = { _ in false }
    stopped.start(every: 0.01)
    pump(until: { false }, timeout: 0.05)
    eq(ticks, stoppedCount, "all providers disabled means no requests")
    stopped.stop()
    Cfg.resetAll()
}
