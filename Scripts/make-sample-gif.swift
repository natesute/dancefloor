// Generates Resources/sample-dancer.gif: a stick figure doing a two-beat bounce.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 240
let frameCount = 16
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frameCount, nil)!
CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)

for f in 0..<frameCount {
    let t = Double(f) / Double(frameCount)          // 0..<1 over two beats
    let beatPhase = (t * 2).truncatingRemainder(dividingBy: 1)
    let bounce = abs(cos(beatPhase * .pi))          // 1 on the beat, 0 between
    let sway = sin(t * 2 * .pi)                     // side to side over the loop

    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))
    ctx.setLineCap(.round)
    ctx.setLineWidth(10)
    ctx.setStrokeColor(CGColor(red: 1, green: 0.35, blue: 0.7, alpha: 1))

    let cx = 120 + 18 * sway
    let hip = 80 - 22 * bounce
    let neck = hip + 70
    // Legs bend when down on the beat.
    let knee = 25 * bounce
    ctx.move(to: CGPoint(x: cx - 30, y: 12)); ctx.addLine(to: CGPoint(x: cx - 18 - knee, y: (hip + 12) / 2)); ctx.addLine(to: CGPoint(x: cx, y: hip))
    ctx.move(to: CGPoint(x: cx + 30, y: 12)); ctx.addLine(to: CGPoint(x: cx + 18 + knee, y: (hip + 12) / 2)); ctx.addLine(to: CGPoint(x: cx, y: hip))
    // Body.
    ctx.move(to: CGPoint(x: cx, y: hip)); ctx.addLine(to: CGPoint(x: cx + 6 * sway, y: neck))
    // Arms up on the beat, out between.
    let armY = neck - 10 + 55 * bounce
    ctx.move(to: CGPoint(x: cx - 55, y: armY)); ctx.addLine(to: CGPoint(x: cx + 6 * sway, y: neck - 8)); ctx.addLine(to: CGPoint(x: cx + 55, y: armY))
    ctx.strokePath()
    // Head.
    ctx.setFillColor(CGColor(red: 1, green: 0.35, blue: 0.7, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: cx + 6 * sway - 20, y: neck + 6, width: 40, height: 40))

    CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / 16]] as CFDictionary)
}
CGImageDestinationFinalize(dest)
