import AppKit
import WebKit

// MARK: - In-app browser login (captures the web session cookie, no DevTools needed)

final class WebLoginWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var webView: WKWebView?
    private var cookieName = ""
    private var domain = ""
    private var onCapture: ((String) -> Void)?
    private var polling = false

    func start(title: String, url: String, domain: String, cookieName: String, onCapture: @escaping (String) -> Void) {
        close()
        self.domain = domain; self.cookieName = cookieName; self.onCapture = onCapture
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = WKWebsiteDataStore.default()   // persistent so the login sticks
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 540, height: 720), configuration: cfg)
        let win = NSWindow(contentRect: wv.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        win.title = title; win.contentView = wv; win.delegate = self; win.isReleasedWhenClosed = false; win.center()
        self.window = win; self.webView = wv
        NSApp.activate(ignoringOtherApps: true); win.makeKeyAndOrderFront(nil)
        if let u = URL(string: url) { wv.load(URLRequest(url: u)) }
        polling = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.poll() }
    }
    private func poll() {
        guard polling, let wv = webView else { return }
        wv.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self = self, self.polling else { return }
            if let c = cookies.first(where: { $0.name == self.cookieName && $0.domain.contains(self.domain) && !$0.value.isEmpty }) {
                self.polling = false
                let cb = self.onCapture
                self.close()
                cb?(c.value)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.poll() }
        }
    }
    func close() {
        polling = false
        if let w = window { w.delegate = nil; w.close() }
        window = nil; webView = nil
    }
    func windowWillClose(_ notification: Notification) { polling = false; window = nil; webView = nil }
}

