import AppKit
import UserNotifications

/// Uses the system notification service, without a notification polling timer.
final class NotificationController: NSObject, UNUserNotificationCenterDelegate {
    private lazy var center = UNUserNotificationCenter.current()
    private var tracker = QuotaAlertTracker(data: Cfg.alertHistory)
    private var submitting = Set<String>()
    private var latestTestRun: String?
    var onStatus: (String) -> Void = { _ in }
    var onOpen: () -> Void = {}

    func start() { center.delegate = self; updatePermissionStatus() }

    func requestPermission() {
        center.requestAuthorization(options: [.alert]) { [weak self] _, error in
            DispatchQueue.main.async {
                if let error = error { self?.onStatus("Notifications unavailable: \(error.localizedDescription)") }
                else { self?.updatePermissionStatus() }
            }
        }
    }

    func updatePermissionStatus() {
        center.getNotificationSettings { [weak self] settings in
            let status: String
            switch settings.authorizationStatus {
            case .authorized, .provisional: status = "Allowed by macOS · Focus may silence banners."
            case .denied: status = "Blocked in System Settings → Notifications."
            case .notDetermined: status = "Choose Enable Notifications to allow alerts."
            @unknown default: status = "Notification permission is unavailable."
            }
            DispatchQueue.main.async { self?.onStatus(status) }
        }
    }

    func record(_ reading: Reading, provider: Provider) {
        center.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self = self, Cfg.isShown(provider) else { return }
                let allowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
                let alerts = self.tracker.observe(reading, provider: provider, now: nowEpoch(),
                                                 lowEnabled: allowed && Cfg.lowAlerts,
                                                 recoveryEnabled: allowed && Cfg.recoveryAlerts)
                Cfg.alertHistory = self.tracker.data
                if !alerts.isEmpty { self.send(alerts) }
            }
        }
    }

    /// Explicit sample readings exercise the same detector and delivery path,
    /// without changing live quota or its persisted notification history.
    func testAlerts() {
        var sample = QuotaAlertTracker()
        let now = nowEpoch()
        func reading(_ used: Double, at: Double, reset: Double) -> Reading {
            Reading(windows: [UsageWindow(label: "5-hour (sample)", kind: .session, usedPercent: used, resetsAt: reset)], fetchedAt: at)
        }
        _ = sample.observe(reading(75, at: now - 3, reset: now - 1), provider: .codex, now: now - 3,
                           lowEnabled: true, recoveryEnabled: true)
        let low = sample.observe(reading(80, at: now - 2, reset: now - 1), provider: .codex, now: now - 2,
                                 lowEnabled: true, recoveryEnabled: true)
        let recovered = sample.observe(reading(5, at: now, reset: now + 18000), provider: .codex, now: now,
                                       lowEnabled: true, recoveryEnabled: true)
        send(low + recovered, test: true)
    }

    private func send(_ alerts: [QuotaAlert], test: Bool = false) {
        center.getNotificationSettings { [weak self] settings in
            guard let self = self else { return }
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                DispatchQueue.main.async { self.onStatus("Alerts are blocked. Enable notifications first.") }
                return
            }
            DispatchQueue.main.async { [self] in
                let testRun = test ? UUID().uuidString : ""
                if test { self.latestTestRun = testRun }
                for (index, alert) in alerts.enumerated() {
                    if !test {
                        guard Cfg.isShown(alert.provider), alert.kind == .low ? Cfg.lowAlerts : Cfg.recoveryAlerts,
                              self.submitting.insert(alert.id).inserted else { continue }
                    }
                    let content = UNMutableNotificationContent()
                    content.title = (test ? "Test · " : "") + alert.title
                    content.body = (test ? "Sample data. " : "") + alert.body
                    content.threadIdentifier = alert.provider.rawValue
                    if test { content.userInfo = ["testRun": testRun] }
                    let id = test ? "aicb-test-\(index)" : alert.id
                    // Space the two sample banners so both can be inspected.
                    let trigger = test ? UNTimeIntervalNotificationTrigger(timeInterval: Double(index * 5 + 1), repeats: false) : nil
                    self.center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger)) { error in
                        DispatchQueue.main.async {
                            if !test { self.submitting.remove(alert.id) }
                            if let error = error { self.onStatus("Could not schedule alert: \(error.localizedDescription)") }
                            else if test { self.onStatus("Test alerts scheduled · sample data, no quota used.") }
                            else { self.tracker.acknowledge(alert); Cfg.alertHistory = self.tracker.data }
                        }
                    }
                }
                if test {
                    // A one-shot verification for the explicit test button, not a
                    // background poll. Scheduling alone does not prove delivery.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                        guard let self = self else { return }
                        self.center.getDeliveredNotifications { delivered in
                            let ids = Set(delivered.filter { $0.request.content.userInfo["testRun"] as? String == testRun }
                                .map { $0.request.identifier })
                            let confirmed = alerts.indices.allSatisfy { ids.contains("aicb-test-\($0)") }
                            DispatchQueue.main.async {
                                guard self.latestTestRun == testRun else { return }
                                self.onStatus(confirmed ? "Both test alerts reached Notification Center."
                                    : "Test delivery is not confirmed. Check Notification Center or Focus.")
                            }
                        }
                    }
                }
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async { [weak self] in self?.onOpen() }
        completionHandler()
    }
}
