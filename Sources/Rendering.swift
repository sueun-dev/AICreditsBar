import AppKit

// MARK: - Rendering

func colorFor(_ w: WindowStat?) -> NSColor {
    guard let w = w else { return Cfg.colorUnknown }
    if w.stale { return Cfg.colorUnknown }
    if w.refilled { return Cfg.colorHigh }
    guard let r = w.remaining else { return Cfg.colorUnknown }
    if r > Cfg.greenAbove { return Cfg.colorHigh }
    if r >= Cfg.yellowAbove { return Cfg.colorMid }
    return Cfg.colorLow
}
func windowText(_ w: WindowStat?) -> String {
    guard let w = w else { return "?" }
    if w.refilled { return "↑" }
    if let r = w.remaining { return "\(r)%" }
    return "?"
}
func barInfo(_ p: ProviderStatus) -> (String, NSColor) {
    guard p.available else { return ("—", Cfg.colorUnknown) }
    let f = p.fiveHour, w = p.weekly
    switch Cfg.displayMode {
    case "week":
        if w != nil { return (windowText(w), colorFor(w)) }
        return (windowText(f), colorFor(f))
    case "both":
        if w != nil {
            let worse = (f?.remaining ?? 101) <= (w?.remaining ?? 101) ? f : w
            return ("\(windowText(f))/\(windowText(w))", colorFor(worse))
        }
        return (windowText(f), colorFor(f))
    case "min":
        let cands = [f, w].compactMap { $0 }
        let worst = cands.min { ($0.remaining ?? 101) < ($1.remaining ?? 101) } ?? f
        return (windowText(worst), colorFor(worst))
    default:
        if f == nil && w != nil { return (windowText(w), colorFor(w)) }
        return (windowText(f), colorFor(f))
    }
}
// Monochrome menu-bar glyphs per provider (template images → tint to the bar appearance).
var glyphCache: [String: NSImage] = [:]
func providerGlyph(_ key: String, _ pt: CGFloat = 16) -> NSImage {
    if let g = glyphCache[key] { return g }
    // Bold monochrome marks → tint white like native menu-bar icons.
    let img = NSImage(size: NSSize(width: pt, height: pt)); img.lockFocus()
    NSColor.black.setFill(); NSColor.black.setStroke()
    let c = NSPoint(x: pt/2, y: pt/2)
    switch key {
    case "Cl": // Claude — Anthropic sunburst
        let rays = 11, rOut = pt*0.49, rIn = pt*0.12, w = pt*0.085
        for i in 0..<rays {
            let a = CGFloat(i)/CGFloat(rays)*2 * .pi
            let d = NSPoint(x: cos(a), y: sin(a)), pp = NSPoint(x: -sin(a), y: cos(a))
            let tip = NSPoint(x: c.x + d.x*rOut, y: c.y + d.y*rOut)
            let b1 = NSPoint(x: c.x + d.x*rIn + pp.x*w, y: c.y + d.y*rIn + pp.y*w)
            let b2 = NSPoint(x: c.x + d.x*rIn - pp.x*w, y: c.y + d.y*rIn - pp.y*w)
            let p = NSBezierPath(); p.move(to: tip); p.line(to: b1); p.line(to: b2); p.close(); p.fill()
        }
        NSBezierPath(ovalIn: NSRect(x: c.x-rIn*1.4, y: c.y-rIn*1.4, width: rIn*2.8, height: rIn*2.8)).fill()
    case "Gm": // Gemini — 4-point sparkle
        let R = pt*0.5, r = pt*0.11
        let pts = [(0.0,R),(r,r),(R,0.0),(r,-r),(0.0,-R),(-r,-r),(-R,0.0),(-r,r)]
        let p = NSBezierPath()
        for (i,(x,y)) in pts.enumerated() {
            let q = NSPoint(x: c.x+CGFloat(x), y: c.y+CGFloat(y)); i==0 ? p.move(to:q) : p.line(to:q)
        }
        p.close(); p.fill()
    default: // "Cx" Codex — OpenAI blossom (6 rounded petals)
        let petalR = pt*0.235, ring = pt*0.255
        for i in 0..<6 {
            let a = (CGFloat(i)*60 - 90) * .pi/180
            let pxc = c.x + cos(a)*ring, pyc = c.y + sin(a)*ring
            NSBezierPath(ovalIn: NSRect(x: pxc-petalR, y: pyc-petalR, width: petalR*2, height: petalR*2)).fill()
        }
        // knot center punched out for the flower look
        NSGraphicsContext.current?.compositingOperation = .clear
        NSBezierPath(ovalIn: NSRect(x: c.x-pt*0.115, y: c.y-pt*0.115, width: pt*0.23, height: pt*0.23)).fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
    }
    img.unlockFocus(); img.isTemplate = true; glyphCache[key] = img; return img
}

func barSegment(_ p: ProviderStatus) -> NSAttributedString {
    let mono = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    let s = NSMutableAttributedString()
    if Cfg.showLabels {
        let att = NSTextAttachment(); att.image = providerGlyph(p.key); att.bounds = NSRect(x: 0, y: -3.5, width: 16, height: 16)
        s.append(NSAttributedString(attachment: att))
        s.append(NSAttributedString(string: " ", attributes: [.font: mono]))
    }
    let (txt, col) = barInfo(p)
    s.append(NSAttributedString(string: txt, attributes: [.font: mono, .foregroundColor: col]))
    return s
}
