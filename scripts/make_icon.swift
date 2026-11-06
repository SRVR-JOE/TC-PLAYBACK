#!/usr/bin/env swift
// Generates App/Resources/Assets.xcassets/AppIcon.appiconset/icon.png (1024×1024).
// Graphite ground, a fine bi-phase (LTC) square-wave trace, and a small amber standby lamp.
// Usage: swift scripts/make_icon.swift [output.png]
import AppKit
import CoreGraphics

let size = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1]
    : "App/Resources/Assets.xcassets/AppIcon.appiconset/icon.png"

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
let S = CGFloat(size)

// Ground: flat graphite (iOS applies the corner mask).
ctx.setFillColor(rgb(0x16181B))
ctx.fill(CGRect(x: 0, y: 0, width: S, height: S))

// Faint graticule: two hairlines framing the trace, like a scope.
ctx.setStrokeColor(rgb(0x2A2E33))
ctx.setLineWidth(3)
for y in [S * 0.5 - 150, S * 0.5 + 150] {
    ctx.move(to: CGPoint(x: 150, y: y)); ctx.addLine(to: CGPoint(x: S - 150, y: y))
}
ctx.strokePath()

// Bi-phase mark: a transition at every bit boundary, plus one mid-bit for a "1".
// A short run of LTC-like bits.
let bits: [Int] = [0, 1, 1, 0, 0, 1, 1, 1, 0]
let left: CGFloat = 150, right: CGFloat = S - 150
let bitW = (right - left) / CGFloat(bits.count)
let amp: CGFloat = 96
let mid = S * 0.5
var level: CGFloat = 1
var x = left
let path = CGMutablePath()
path.move(to: CGPoint(x: x, y: mid + amp * level))
for (i, b) in bits.enumerated() {
    // boundary transition (none before the first bit, so the trace starts clean)
    if i > 0 {
        level = -level
        path.addLine(to: CGPoint(x: x, y: mid + amp * level))
    }
    if b == 1 {
        path.addLine(to: CGPoint(x: x + bitW / 2, y: mid + amp * level))
        level = -level
        path.addLine(to: CGPoint(x: x + bitW / 2, y: mid + amp * level))
    }
    x += bitW
    path.addLine(to: CGPoint(x: x, y: mid + amp * level))
}
ctx.addPath(path)
ctx.setStrokeColor(rgb(0xD9DEE4))
ctx.setLineWidth(11)
ctx.setLineJoin(.miter)
ctx.setLineCap(.butt)
ctx.strokePath()

// Amber standby lamp, top right, with a thin dark rim (no glow).
let lampR: CGFloat = 34
let lampC = CGPoint(x: S - 150 - lampR, y: S - 186)
ctx.setFillColor(rgb(0x0A0B0D))
ctx.fillEllipse(in: CGRect(x: lampC.x - lampR - 6, y: lampC.y - lampR - 6, width: (lampR + 6) * 2, height: (lampR + 6) * 2))
ctx.setFillColor(rgb(0xFFB020))
ctx.fillEllipse(in: CGRect(x: lampC.x - lampR, y: lampC.y - lampR, width: lampR * 2, height: lampR * 2))

let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
let data = rep.representation(using: .png, properties: [:])!
try! data.write(to: URL(fileURLWithPath: out))
print(out)
