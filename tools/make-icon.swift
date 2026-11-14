// Renders Resources/AppIcon.icns. Run from the repo root:  swift tools/make-icon.swift
import AppKit

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = CGFloat(px) / 1024
    ctx.scaleBy(x: s, y: s)

    // Body on Apple's macOS icon grid: 824pt square, 100pt margin.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    NSColor.black.setFill()
    shape.fill()
    ctx.restoreGState()

    ctx.saveGState()
    shape.addClip()
    NSGradient(colors: [NSColor(srgbRed: 0.36, green: 0.42, blue: 0.98, alpha: 1),
                        NSColor(srgbRed: 0.52, green: 0.26, blue: 0.86, alpha: 1)])!
        .draw(in: body, angle: -60)
    // Soft top highlight.
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.18), NSColor.white.withAlphaComponent(0)])!
        .draw(in: CGRect(x: 100, y: 512, width: 824, height: 412), angle: -90)
    ctx.restoreGState()

    // Glyph: "M" and a down arrow, the Markdown mark.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: NSColor.black.withAlphaComponent(0.22).cgColor)
    NSColor.white.setFill()
    let font = NSFont.systemFont(ofSize: 430, weight: .heavy)
    let m = NSAttributedString(string: "M", attributes: [.font: font, .foregroundColor: NSColor.white])
    let mSize = m.size()
    let arrowW: CGFloat = 210, gap: CGFloat = 26
    let total = mSize.width + gap + arrowW
    let left = 512 - total / 2
    m.draw(at: CGPoint(x: left, y: 512 - mSize.height / 2 + 8))

    let ax = left + mSize.width + gap
    let top: CGFloat = 690, bottom: CGFloat = 330, stem: CGFloat = 84, headH: CGFloat = 165
    let arrow = NSBezierPath()
    arrow.move(to: CGPoint(x: ax + (arrowW - stem) / 2, y: top))
    arrow.line(to: CGPoint(x: ax + (arrowW + stem) / 2, y: top))
    arrow.line(to: CGPoint(x: ax + (arrowW + stem) / 2, y: bottom + headH))
    arrow.line(to: CGPoint(x: ax + arrowW, y: bottom + headH))
    arrow.line(to: CGPoint(x: ax + arrowW / 2, y: bottom))
    arrow.line(to: CGPoint(x: ax, y: bottom + headH))
    arrow.line(to: CGPoint(x: ax + (arrowW - stem) / 2, y: bottom + headH))
    arrow.close()
    arrow.lineJoinStyle = .round
    arrow.fill()
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try! fm.createDirectory(atPath: "Resources", withIntermediateDirectories: true)
try! render(1024).write(to: URL(fileURLWithPath: "Resources/AppIcon-1024.png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try! p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
