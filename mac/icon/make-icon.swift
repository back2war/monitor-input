// Renders the app icon (monitor with a blue screen and "switch" arrows, same geometry as
// windows/icon/make-icon.ps1) into ../AppIcon.icns.
// Usage: swift make-icon.swift [--preview <dir>]   (needs iconutil from the Xcode Command Line Tools)

import AppKit

func roundedRect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: r, yRadius: r)
}

func drawArrow(from x1: CGFloat, to x2: CGFloat, y: CGFloat, head: CGFloat, width: CGFloat) {
    // Horizontal shaft from x1 to x2 with a filled triangular head at x2.
    let dir: CGFloat = x2 > x1 ? 1 : -1
    let shaft = NSBezierPath()
    shaft.move(to: NSPoint(x: x1, y: y))
    shaft.line(to: NSPoint(x: x2 - dir * head * 0.6, y: y))
    shaft.lineWidth = width
    shaft.stroke()
    let tip = NSBezierPath()
    tip.move(to: NSPoint(x: x2, y: y))
    tip.line(to: NSPoint(x: x2 - dir * head, y: y - head * 0.75))
    tip.line(to: NSPoint(x: x2 - dir * head, y: y + head * 0.75))
    tip.close()
    tip.fill()
}

func render(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    // y grows down, like the Windows script. macOS icons keep a margin around the artwork (none at tiny sizes).
    let margin = CGFloat(px) * (px >= 64 ? 0.08 : 0.02)
    let t = NSAffineTransform()
    t.translateX(by: margin, yBy: CGFloat(px) - margin)
    t.scaleX(by: 1, yBy: -1)
    t.concat()
    let s = CGFloat(px) - 2 * margin

    let bezel = NSColor(srgbRed: 71 / 255, green: 85 / 255, blue: 105 / 255, alpha: 1)    // slate
    let top = NSColor(srgbRed: 56 / 255, green: 189 / 255, blue: 248 / 255, alpha: 1)    // sky
    let bottom = NSColor(srgbRed: 37 / 255, green: 99 / 255, blue: 235 / 255, alpha: 1)  // blue

    // Body (bezel)
    let bx = s * 0.03, by = s * 0.08, bw = s * 0.94, bh = s * 0.66
    bezel.setFill()
    roundedRect(bx, by, bw, bh, max(1, s * 0.08)).fill()

    // Screen; in the flipped space angle 90 runs from the top edge to the bottom edge
    let inset = max(1.5, s * 0.07)
    let sx = bx + inset, sy = by + inset, sw = bw - 2 * inset, sh = bh - 2 * inset
    NSGradient(starting: top, ending: bottom)!.draw(in: roundedRect(sx, sy, sw, sh, max(0, s * 0.035)), angle: 90)

    // Stand: neck + base
    bezel.setFill()
    let neckW = s * 0.16, neckH = s * 0.10
    NSBezierPath(rect: NSRect(x: (s - neckW) / 2, y: by + bh - 0.5, width: neckW, height: neckH + 0.5)).fill()
    let baseW = s * 0.52, baseH = max(1.5, s * 0.08)
    roundedRect((s - baseW) / 2, by + bh + neckH, baseW, baseH, baseH / 2).fill()

    // Switch arrows: right arrow on top, left arrow below
    NSColor.white.set()
    let stroke = max(1.4, s * 0.075), head = max(2.6, s * 0.15)
    let ax1 = sx + sw * 0.18, ax2 = sx + sw * 0.82
    drawArrow(from: ax1, to: ax2, y: sy + sh * 0.32, head: head, width: stroke)
    drawArrow(from: ax2, to: ax1, y: sy + sh * 0.70, head: head, width: stroke)
    return rep
}

let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

var preview: URL?
if let i = CommandLine.arguments.firstIndex(of: "--preview"), i + 1 < CommandLine.arguments.count {
    preview = URL(fileURLWithPath: CommandLine.arguments[i + 1])
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let png = render(base * scale).representation(using: .png, properties: [:])!
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try png.write(to: iconset.appendingPathComponent(name))
        if let preview = preview { try png.write(to: preview.appendingPathComponent("preview-\(base * scale).png")) }
    }
}

let out = here.deletingLastPathComponent().appendingPathComponent("AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try p.run()
p.waitUntilExit()
guard p.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote \(out.path)")
