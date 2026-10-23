// Independent public-AppKit status-item lifecycle probe. No AICreditsBar source.
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.finishLaunching()
var item: NSStatusItem?
func replaceItem(_ step: Int) {
    if let previous = item { NSStatusBar.system.removeStatusItem(previous) }
    item = nil
    if step < 40 {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item?.button?.image = NSImage(systemSymbolName: "testtube.2", accessibilityDescription: "Temporary diagnostic")
    }
    print("Status lifecycle step \(step)")
    fflush(stdout)
}
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 180),
                      styleMask: [.titled, .closable], backing: .buffered, defer: false)
window.title = "Independent AppKit diagnostic"
window.isReleasedWhenClosed = false
window.contentView?.addSubview(NSTextField(labelWithString: "Temporary AppKit-only lifecycle test"))
window.center()
window.makeKeyAndOrderFront(nil)
for step in 0...40 {
    DispatchQueue.main.asyncAfter(deadline: .now() + Double(step) * 0.1) { replaceItem(step) }
}
DispatchQueue.main.asyncAfter(deadline: .now() + 8) { app.terminate(nil) }
app.run()
