// Draws Resources/AppIcon.icns: a white dancer mid-move on a pink-to-violet squircle.
import AppKit

func render(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: s, y: s)

    // macOS icon grid: 824pt squircle centred in 1024.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    NSGradient(colors: [NSColor(red: 1.0, green: 0.36, blue: 0.62, alpha: 1),
                        NSColor(red: 0.45, green: 0.27, blue: 0.95, alpha: 1)])!.draw(in: squircle, angle: -60)

    // Floor glow.
    NSColor.white.withAlphaComponent(0.16).setFill()
    NSBezierPath(ovalIn: NSRect(x: 290, y: 175, width: 444, height: 70)).fill()

    // Dancer.
    NSColor.white.setStroke()
    NSColor.white.setFill()
    let figure = NSBezierPath()
    figure.lineWidth = 62
    figure.lineCapStyle = .round
    figure.lineJoinStyle = .round
    // Legs: one planted, one kicked out.
    figure.move(to: NSPoint(x: 400, y: 225)); figure.line(to: NSPoint(x: 470, y: 380)); figure.line(to: NSPoint(x: 515, y: 470))
    figure.move(to: NSPoint(x: 700, y: 330)); figure.line(to: NSPoint(x: 590, y: 390)); figure.line(to: NSPoint(x: 515, y: 470))
    // Torso.
    figure.move(to: NSPoint(x: 515, y: 470)); figure.line(to: NSPoint(x: 545, y: 640))
    // Arms: one pointing up, one down across.
    figure.move(to: NSPoint(x: 720, y: 800)); figure.line(to: NSPoint(x: 640, y: 690)); figure.line(to: NSPoint(x: 545, y: 640))
    figure.line(to: NSPoint(x: 420, y: 585)); figure.line(to: NSPoint(x: 330, y: 500))
    figure.stroke()
    NSBezierPath(ovalIn: NSRect(x: 470, y: 660, width: 120, height: 120)).fill()

    // Music notes.
    func note(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) {
        NSColor.white.withAlphaComponent(0.85).setFill()
        NSBezierPath(ovalIn: NSRect(x: x, y: y, width: r * 1.3, height: r)).fill()
        NSBezierPath(rect: NSRect(x: x + r * 1.3 - 12, y: y + r / 2, width: 12, height: r * 2.2)).fill()
    }
    note(250, 700, 56)
    note(760, 560, 44)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! render(base * scale).representation(using: .png, properties: [:])!
            .write(to: iconset.appendingPathComponent(name))
    }
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try! task.run()
task.waitUntilExit()
try! render(512).representation(using: .png, properties: [:])!.write(to: out.deletingPathExtension().appendingPathExtension("png"))
