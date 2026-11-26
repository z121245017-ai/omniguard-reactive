import Foundation
import CoreGraphics
import ImageIO
import AppKit

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "docs/omniguard_logo.png"
let size = 512

guard let ctx = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fatalError("CGContext failed") }

ctx.translateBy(x: 0, y: CGFloat(size))
ctx.scaleBy(x: 1, y: -1)

// Deep midnight background
ctx.setFillColor(NSColor(red: 0.043, green: 0.063, blue: 0.125, alpha: 1.0).cgColor)
ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))

// Outer subtle border ring
let ringRect = CGRect(x: 24, y: 24, width: size - 48, height: size - 48)
ctx.setStrokeColor(NSColor(red: 0.220, green: 0.741, blue: 0.973, alpha: 0.35).cgColor)
ctx.setLineWidth(4)
ctx.strokeEllipse(in: ringRect)

// Central Shield Polygon
let shield = CGMutablePath()
shield.move(to: CGPoint(x: 256, y: 84))
shield.addLine(to: CGPoint(x: 394, y: 142))
shield.addLine(to: CGPoint(x: 376, y: 294))
shield.addQuadCurve(to: CGPoint(x: 256, y: 428), control: CGPoint(x: 356, y: 382))
shield.addQuadCurve(to: CGPoint(x: 136, y: 294), control: CGPoint(x: 156, y: 382))
shield.addLine(to: CGPoint(x: 118, y: 142))
shield.closeSubpath()

ctx.setFillColor(NSColor(red: 0.075, green: 0.122, blue: 0.235, alpha: 1.0).cgColor)
ctx.addPath(shield)
ctx.fillPath()

ctx.setStrokeColor(NSColor(red: 0.220, green: 0.741, blue: 0.973, alpha: 0.95).cgColor)
ctx.setLineWidth(10)
ctx.addPath(shield)
ctx.strokePath()

// 3-chain lightning triad nodes inside shield (Base -> Lasna -> Unichain)
let pBase = CGPoint(x: 186, y: 274)
let pLasna = CGPoint(x: 256, y: 184)
let pUni = CGPoint(x: 326, y: 274)

ctx.setStrokeColor(NSColor(red: 0.133, green: 0.773, blue: 0.369, alpha: 0.95).cgColor)
ctx.setLineWidth(8)
ctx.move(to: pBase)
ctx.addLine(to: pLasna)
ctx.addLine(to: pUni)
ctx.strokePath()

// Bottom pulse line
ctx.setStrokeColor(NSColor(red: 0.961, green: 0.620, blue: 0.043, alpha: 0.85).cgColor)
ctx.setLineWidth(5)
ctx.move(to: CGPoint(x: 194, y: 326))
ctx.addLine(to: CGPoint(x: 234, y: 326))
ctx.addLine(to: CGPoint(x: 250, y: 300))
ctx.addLine(to: CGPoint(x: 266, y: 350))
ctx.addLine(to: CGPoint(x: 282, y: 326))
ctx.addLine(to: CGPoint(x: 318, y: 326))
ctx.strokePath()

for (pt, col) in [
    (pBase, NSColor(red: 0.220, green: 0.741, blue: 0.973, alpha: 1.0)),
    (pLasna, NSColor(red: 0.133, green: 0.773, blue: 0.369, alpha: 1.0)),
    (pUni, NSColor(red: 0.925, green: 0.282, blue: 0.600, alpha: 1.0)),
] {
    ctx.setFillColor(col.cgColor)
    ctx.fillEllipse(in: CGRect(x: pt.x - 18, y: pt.y - 18, width: 36, height: 36))
    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.setLineWidth(3)
    ctx.strokeEllipse(in: CGRect(x: pt.x - 18, y: pt.y - 18, width: 36, height: 36))
}

guard let img = ctx.makeImage() else { fatalError("makeImage failed") }
let url = URL(fileURLWithPath: outPath)
try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { fatalError("dest failed") }
CGImageDestinationAddImage(dest, img, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("finalize failed") }
print("Rendered OmniGuard logo:", outPath)
