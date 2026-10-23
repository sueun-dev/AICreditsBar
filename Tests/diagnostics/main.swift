// Minimal macOS screen-capture diagnostic: AppKit only, no AICreditsBar code.
// Build as an app, show its window, then capture it and inspect unified logs.
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.finishLaunching()
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 400),
                      styleMask: [.titled, .closable], backing: .buffered, defer: false)
window.title = "AppKit capture diagnostic"
window.isReleasedWhenClosed = false
let label = NSTextField(wrappingLabelWithString:
    "This is a standard NSWindow with one text label.\n\nNo AICreditsBar code, custom layout, usage API or status item is loaded.")
label.frame = NSRect(x: 24, y: 160, width: 400, height: 180)
window.contentView?.addSubview(label)
window.center()
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
DispatchQueue.main.asyncAfter(deadline: .now() + 180) { app.terminate(nil) }
app.run()
