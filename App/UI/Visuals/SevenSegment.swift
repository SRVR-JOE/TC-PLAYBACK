import SwiftUI

// Owned by the VISUALS agent. Crisp, flat seven-segment face for the timecode clock.
// Lit segments in the clock colour; unlit segments as a faint ghost (~6 %). No glow.

struct SevenSegmentText: View {
    let text: String
    let color: Color
    var ghostOpacity: Double = 0.06

    // Geometry in units of digit height.
    static let digitWidth: CGFloat = 0.54
    static let thickness: CGFloat = 0.105
    static let digitGap: CGFloat = 0.12
    static let sepWidth: CGFloat = 0.30
    static let segGap: CGFloat = 0.018

    /// Total width for `text` at height 1.
    static func unitWidth(_ text: String) -> CGFloat {
        var w: CGFloat = 0
        for (i, ch) in text.enumerated() {
            if i > 0 { w += digitGap }
            w += (ch == ":" || ch == ";") ? sepWidth - digitGap : digitWidth
        }
        return w
    }

    var body: some View {
        Canvas { gc, size in
            let uw = Self.unitWidth(text)
            let h = min(size.height * 0.86, size.width / uw)
            let totalW = uw * h
            var x = (size.width - totalW) / 2
            let y = (size.height - h) / 2
            var lit = Path(), ghost = Path()
            for (i, ch) in text.enumerated() {
                if i > 0 { x += Self.digitGap * h }
                if ch == ":" || ch == ";" {
                    let w = (Self.sepWidth - Self.digitGap) * h
                    Self.separator(ch == ";", in: CGRect(x: x, y: y, width: w, height: h), into: &lit)
                    x += w
                } else {
                    let cell = CGRect(x: x, y: y, width: Self.digitWidth * h, height: h)
                    let on = Self.segments(for: ch)
                    for s in 0..<7 {
                        let p = Self.segment(s, in: cell)
                        if on & (1 << s) != 0 { lit.addPath(p) } else { ghost.addPath(p) }
                    }
                    x += Self.digitWidth * h
                }
            }
            gc.fill(ghost, with: .color(color.opacity(ghostOpacity)))
            gc.fill(lit, with: .color(color))
        }
    }

    /// Bit mask a,b,c,d,e,f,g = bits 0…6.
    static func segments(for ch: Character) -> UInt8 {
        switch ch {
        case "0": 0b0111111
        case "1": 0b0000110
        case "2": 0b1011011
        case "3": 0b1001111
        case "4": 0b1100110
        case "5": 0b1101101
        case "6": 0b1111101
        case "7": 0b0000111
        case "8": 0b1111111
        case "9": 0b1101111
        case "-": 0b1000000
        default: 0
        }
    }

    /// Hexagonal (bevel-ended) segment polygon.
    static func segment(_ index: Int, in r: CGRect) -> Path {
        let h = r.height, t = thickness * h, g = segGap * h
        let left = r.minX + t / 2, right = r.maxX - t / 2
        let top = r.minY + t / 2, mid = r.midY, bottom = r.maxY - t / 2
        switch index {
        case 0: return horizontal(y: top, x0: left, x1: right, t: t, g: g)
        case 1: return vertical(x: right, y0: top, y1: mid, t: t, g: g)
        case 2: return vertical(x: right, y0: mid, y1: bottom, t: t, g: g)
        case 3: return horizontal(y: bottom, x0: left, x1: right, t: t, g: g)
        case 4: return vertical(x: left, y0: mid, y1: bottom, t: t, g: g)
        case 5: return vertical(x: left, y0: top, y1: mid, t: t, g: g)
        default: return horizontal(y: mid, x0: left, x1: right, t: t, g: g)
        }
    }

    private static func horizontal(y: CGFloat, x0: CGFloat, x1: CGFloat, t: CGFloat, g: CGFloat) -> Path {
        let a = x0 + g, b = x1 - g, ht = t / 2
        var p = Path()
        p.move(to: CGPoint(x: a, y: y))
        p.addLine(to: CGPoint(x: a + ht, y: y - ht))
        p.addLine(to: CGPoint(x: b - ht, y: y - ht))
        p.addLine(to: CGPoint(x: b, y: y))
        p.addLine(to: CGPoint(x: b - ht, y: y + ht))
        p.addLine(to: CGPoint(x: a + ht, y: y + ht))
        p.closeSubpath()
        return p
    }

    private static func vertical(x: CGFloat, y0: CGFloat, y1: CGFloat, t: CGFloat, g: CGFloat) -> Path {
        let a = y0 + g, b = y1 - g, ht = t / 2
        var p = Path()
        p.move(to: CGPoint(x: x, y: a))
        p.addLine(to: CGPoint(x: x + ht, y: a + ht))
        p.addLine(to: CGPoint(x: x + ht, y: b - ht))
        p.addLine(to: CGPoint(x: x, y: b))
        p.addLine(to: CGPoint(x: x - ht, y: b - ht))
        p.addLine(to: CGPoint(x: x - ht, y: a + ht))
        p.closeSubpath()
        return p
    }

    /// ":" = two square dots; ";" (drop-frame) = upper dot plus a lower dot with a short tail.
    private static func separator(_ semicolon: Bool, in r: CGRect, into path: inout Path) {
        let d = thickness * r.height
        let cx = r.midX
        let upper = CGRect(x: cx - d / 2, y: r.minY + r.height * 0.30 - d / 2, width: d, height: d)
        let lower = CGRect(x: cx - d / 2, y: r.minY + r.height * 0.70 - d / 2, width: d, height: d)
        path.addRect(upper)
        path.addRect(lower)
        if semicolon {
            var tail = Path()
            tail.move(to: CGPoint(x: lower.maxX, y: lower.maxY))
            tail.addLine(to: CGPoint(x: lower.maxX - d * 0.55, y: lower.maxY + d * 1.0))
            tail.addLine(to: CGPoint(x: lower.minX - d * 0.35, y: lower.maxY + d * 1.0))
            tail.addLine(to: CGPoint(x: lower.minX, y: lower.maxY))
            tail.closeSubpath()
            path.addPath(tail)
        }
    }
}
