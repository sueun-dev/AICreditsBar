import AppKit

/// Minimal SVG path-data reader (M L H V C S Q T A Z, absolute and relative) → NSBezierPath,
/// in the SVG's own y-down coordinates.
func svgPath(_ d: String) -> NSBezierPath {
    var tokens: [String] = [], number = ""
    func flush() { if !number.isEmpty { tokens.append(number); number = "" } }
    for ch in d {
        if ch.isLetter && ch != "e" && ch != "E" { flush(); tokens.append(String(ch)) }
        else if ch == "-" && !(number.last == "e" || number.last == "E") { flush(); number = "-" }
        else if ch == "." && number.contains(".") { flush(); number = "." }
        else if ch == " " || ch == "," || ch == "\n" { flush() }
        else { number.append(ch) }
    }
    flush()

    let path = NSBezierPath()
    var i = 0, cmd = "M"
    var cur = NSPoint.zero, start = NSPoint.zero, lastControl: NSPoint? = nil, lastQuad: NSPoint? = nil
    func num() -> CGFloat { defer { i += 1 }; return CGFloat(Double(tokens[i]) ?? 0) }
    func flag() -> Bool {   // arc flags may be packed: "0 0 1" or "001"
        let t = tokens[i]
        if t.count > 1, let f = t.first, f == "0" || f == "1" { tokens[i] = String(t.dropFirst()); return f == "1" }
        i += 1; return t == "1"
    }
    while i < tokens.count {
        if let c = tokens[i].first, c.isLetter { cmd = tokens[i]; i += 1 }
        let rel = cmd == cmd.lowercased(), base = rel ? cur : .zero
        func pt() -> NSPoint { let x = num(), y = num(); return NSPoint(x: base.x + x, y: base.y + y) }
        switch cmd.uppercased() {
        case "M":
            cur = pt(); start = cur; path.move(to: cur); cmd = rel ? "l" : "L"; lastControl = nil; lastQuad = nil
        case "L": cur = pt(); path.line(to: cur); lastControl = nil; lastQuad = nil
        case "H": cur = NSPoint(x: (rel ? cur.x : 0) + num(), y: cur.y); path.line(to: cur); lastControl = nil; lastQuad = nil
        case "V": cur = NSPoint(x: cur.x, y: (rel ? cur.y : 0) + num()); path.line(to: cur); lastControl = nil; lastQuad = nil
        case "C":
            let c1 = pt(), c2 = pt(), p = pt()
            path.curve(to: p, controlPoint1: c1, controlPoint2: c2); cur = p; lastControl = c2; lastQuad = nil
        case "S":
            let c1 = lastControl.map { NSPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
            let c2 = pt(), p = pt()
            path.curve(to: p, controlPoint1: c1, controlPoint2: c2); cur = p; lastControl = c2; lastQuad = nil
        case "Q", "T":
            let q = cmd.uppercased() == "Q" ? pt() : (lastQuad.map { NSPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur)
            let p = pt()
            path.curve(to: p, controlPoint1: NSPoint(x: cur.x + 2 / 3 * (q.x - cur.x), y: cur.y + 2 / 3 * (q.y - cur.y)),
                       controlPoint2: NSPoint(x: p.x + 2 / 3 * (q.x - p.x), y: p.y + 2 / 3 * (q.y - p.y)))
            cur = p; lastQuad = q; lastControl = nil
        case "A":
            var rx = abs(num()), ry = abs(num()); let phi = num() * .pi / 180
            let large = flag(), sweep = flag(); let p = pt()
            defer { cur = p; lastControl = nil; lastQuad = nil }
            if rx == 0 || ry == 0 { path.line(to: p); continue }
            // endpoint → center parameterization (SVG spec F.6.5)
            let dx = (cur.x - p.x) / 2, dy = (cur.y - p.y) / 2
            let x1 = cos(phi) * dx + sin(phi) * dy, y1 = -sin(phi) * dx + cos(phi) * dy
            let lambda = x1 * x1 / (rx * rx) + y1 * y1 / (ry * ry)
            if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
            let num2 = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
            var k = sqrt(max(0, num2 / (rx * rx * y1 * y1 + ry * ry * x1 * x1)))
            if large == sweep { k = -k }
            let cx1 = k * rx * y1 / ry, cy1 = -k * ry * x1 / rx
            let cx = cos(phi) * cx1 - sin(phi) * cy1 + (cur.x + p.x) / 2, cy = sin(phi) * cx1 + cos(phi) * cy1 + (cur.y + p.y) / 2
            func ang(_ ux: CGFloat, _ uy: CGFloat) -> CGFloat { atan2(uy, ux) }
            let t1 = ang((x1 - cx1) / rx, (y1 - cy1) / ry)
            var dt = ang((-x1 - cx1) / rx, (-y1 - cy1) / ry) - t1
            if sweep && dt < 0 { dt += 2 * .pi } else if !sweep && dt > 0 { dt -= 2 * .pi }
            let segments = max(1, Int(ceil(abs(dt) / (.pi / 2))))
            let step = dt / CGFloat(segments), alpha = 4 / 3 * tan(step / 4)
            func onEllipse(_ t: CGFloat) -> (NSPoint, NSPoint) {   // point and derivative
                let ex = rx * cos(t), ey = ry * sin(t), dxe = -rx * sin(t), dye = ry * cos(t)
                return (NSPoint(x: cx + cos(phi) * ex - sin(phi) * ey, y: cy + sin(phi) * ex + cos(phi) * ey),
                        NSPoint(x: cos(phi) * dxe - sin(phi) * dye, y: sin(phi) * dxe + cos(phi) * dye))
            }
            for s in 0..<segments {
                let ta = t1 + CGFloat(s) * step, tb = ta + step
                let (pa, da) = onEllipse(ta), (pb, db) = onEllipse(tb)
                path.curve(to: pb, controlPoint1: NSPoint(x: pa.x + alpha * da.x, y: pa.y + alpha * da.y),
                           controlPoint2: NSPoint(x: pb.x - alpha * db.x, y: pb.y - alpha * db.y))
            }
        case "Z":
            path.close(); cur = start; lastControl = nil; lastQuad = nil
            if i < tokens.count, tokens[i].first?.isLetter == false { i += 1 }   // stray number after Z
        default:
            i += 1
        }
    }
    return path
}
