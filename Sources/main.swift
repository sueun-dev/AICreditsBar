import AppKit

// AICreditsBar — macOS menu-bar widget showing how much of your Codex and Claude
// plan limits is left, from each provider's official usage API.

handleCLIFlags()   // --once / --dump-config / --render-preview / --render-settings exit here

// Single instance: if another copy is already in the menu bar, hand it --settings and bow out.
let myPid = ProcessInfo.processInfo.processIdentifier
if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.sueun.aicreditsbar")
    .contains(where: { $0.processIdentifier != myPid }) {
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
