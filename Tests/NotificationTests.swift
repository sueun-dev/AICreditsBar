import UserNotifications

private final class FakeNotifications {
    var status = UNAuthorizationStatus.authorized
    var delayed = false
    var queries: [(UNAuthorizationStatus) -> Void] = []
    var requests: [UNNotificationRequest] = []
    var replies: [(Error?) -> Void] = []
    func read(_ completion: @escaping (UNAuthorizationStatus) -> Void) {
        if delayed { queries.append(completion) } else { completion(status) }
    }
    func add(_ request: UNNotificationRequest, _ completion: @escaping (Error?) -> Void) {
        requests.append(request); replies.append(completion)
    }
    func finish(_ error: Error? = nil) {
        let pending = replies; replies.removeAll()
        pending.forEach { $0(error) }
        pump(until: { false }, timeout: 0.02)
    }
}

func runNotificationTests(now: Double) {
    Cfg.resetAll(); Cfg.alertHistory = nil
    var clock = now
    func reading(_ used: Double, at: Double) -> Reading {
        Reading(windows: [UsageWindow(label: "5-hour", kind: .session, usedPercent: used, resetsAt: now + 600)], fetchedAt: at)
    }

    // OS scheduling callbacks, not observation alone, consume a notification.
    let service = FakeNotifications()
    let controller = NotificationController(clock: { clock }, authorization: service.read, submit: service.add)
    controller.record(reading(80, at: clock), provider: .codex)
    pump(until: { service.requests.count == 1 })
    eq(service.requests.count, 1, "notification controller submits the low alert")
    eq(service.requests.first?.content.title, "Codex: 20% remaining", "native notification carries the real remaining percentage")
    check(service.requests.first?.trigger == nil, "real quota alerts are immediate rather than repeating timers")
    check(service.requests.first?.content.sound == nil, "quota alerts do not add notification sounds")
    clock += 1
    controller.record(reading(85, at: clock), provider: .codex)
    pump(until: { false }, timeout: 0.03)
    eq(service.requests.count, 1, "an in-flight OS submission suppresses concurrent duplicates")
    service.finish(UsageError("simulated delivery failure"))
    clock += 1
    controller.record(reading(90, at: clock), provider: .codex)
    pump(until: { service.requests.count == 2 })
    eq(service.requests.count, 2, "failed scheduling retries on the next fresh reading")
    service.finish()
    clock += 1
    controller.record(reading(95, at: clock), provider: .codex)
    pump(until: { false }, timeout: 0.03)
    eq(service.requests.count, 2, "successful OS callback consumes the alert")
    let relaunched = NotificationController(clock: { clock }, authorization: service.read, submit: service.add)
    clock += 1
    relaunched.record(reading(95, at: clock), provider: .codex)
    pump(until: { false }, timeout: 0.03)
    eq(service.requests.count, 2, "a new controller restores the acknowledged history from defaults")

    // A later healthy response wins even if an older permission RPC finishes last.
    Cfg.alertHistory = nil
    let delayed = FakeNotifications(); delayed.delayed = true
    let racing = NotificationController(clock: { clock }, authorization: delayed.read, submit: delayed.add)
    racing.record(reading(85, at: clock), provider: .codex)
    delayed.queries[0](.authorized)
    pump(until: { delayed.queries.count == 2 })
    clock += 1
    racing.record(reading(40, at: clock), provider: .codex)
    delayed.queries[2](.authorized)
    pump(until: { false }, timeout: 0.03)
    delayed.queries[1](.authorized)
    pump(until: { false }, timeout: 0.03)
    eq(delayed.requests.count, 0, "delayed authorization cannot submit a superseded low alert")

    // Permission and setting changes are checked without touching real OS settings.
    Cfg.alertHistory = nil
    let denied = FakeNotifications(); denied.status = .denied
    let permission = NotificationController(clock: { clock }, authorization: denied.read, submit: denied.add)
    permission.record(reading(85, at: clock), provider: .claude)
    pump(until: { false }, timeout: 0.03)
    eq(denied.requests.count, 0, "denied notification permission schedules nothing")
    denied.status = .authorized; clock += 1
    permission.record(reading(86, at: clock), provider: .claude)
    pump(until: { denied.requests.count == 1 })
    eq(denied.requests.count, 1, "a fresh low reading can alert after permission is granted")
    denied.finish()

    Cfg.alertHistory = nil
    let toggled = FakeNotifications(); toggled.delayed = true
    let preferences = NotificationController(clock: { clock }, authorization: toggled.read, submit: toggled.add)
    preferences.record(reading(85, at: clock), provider: .codex)
    toggled.queries[0](.authorized)
    pump(until: { toggled.queries.count == 2 })
    Cfg.lowAlerts = false
    toggled.queries[1](.authorized)
    pump(until: { false }, timeout: 0.03)
    eq(toggled.requests.count, 0, "disabling low alerts before submission cancels the pending banner")
    Cfg.lowAlerts = true
    clock += 1
    preferences.record(reading(86, at: clock), provider: .codex)
    Cfg.setShown(.codex, false)
    toggled.queries[2](.authorized)
    pump(until: { false }, timeout: 0.03)
    eq(toggled.requests.count, 0, "disabling the provider while permission is pending cancels its alert")
    Cfg.resetAll(); Cfg.alertHistory = nil
}
