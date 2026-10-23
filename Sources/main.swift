import AppKit

// AICreditsBar — macOS menu-bar widget showing how much of your Codex and Claude
// plan limits is left, from each provider's official usage API.

handleCLIFlags()   // --once / --dump-config / --render-preview / --render-settings exit here

// Single instance, including simultaneous launches before AppKit registers a process.
let instance: AppInstance?
do {
    let cache = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    instance = try AppInstance.acquire(at: cache.appendingPathComponent("com.sueun.aicreditsbar/instance.lock").path)
} catch {
    fputs("Cannot acquire AICreditsBar instance lock: \(error.localizedDescription)\n", stderr)
    exit(1)
}
if instance == nil {
    if CommandLine.arguments.contains("--settings") {
        DistributedNotificationCenter.default().postNotificationName(showSettingsNotification, object: nil, userInfo: nil,
                                                                     deliverImmediately: true)
    }
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
withExtendedLifetime(instance) {}
