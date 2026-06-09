import AppKit

// AICreditsBar — macOS menu-bar widget: remaining token/quota for Codex, Claude, Gemini.
// See Sources/ for the modules; this file is just the entry point.

handleCLIFlags()   // services --once / --dump-config / --set-* / --render-settings, then exits

// Single-instance: if another copy is already in the menu bar, bow out quietly.
let myPid = ProcessInfo.processInfo.processIdentifier
if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.sueun.aicreditsbar")
    .contains(where: { $0.processIdentifier != myPid }) { exit(0) }

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
