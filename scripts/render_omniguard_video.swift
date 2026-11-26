import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import AppKit

let args = CommandLine.arguments
let framesDir = args.count > 1 ? args[1] : "docs/frames"
let outVideo = args.count > 2 ? args[2] : "docs/demo.mp4"

struct Slide { let img: String?; let badge: String; let title: String; let sub: String; let cap: String; let dur: Double }
let slides: [Slide] = [
    Slide(img: nil, badge: "REACTIVE OMNI BUILDATHON · TRACK 1: EVERY SECOND COUNTS", title: "OmniGuard", sub: "Native Reactive Omni (0x8888...8888) Sub-Second Cross-Chain Vault Circuit-Breaker & Keeper-Less Stop-Loss", cap: "Live on Base Sepolia (84532) ↔ Reactive Lasna Omni (5318007) ↔ Unichain Sepolia (1301) · Measured: 1s Base / 3s Unichain", dur: 5.5),
    Slide(img: "\(framesDir)/01-live-3chain-rpc.png", badge: "01 · LIVE 3-CHAIN TESTNET PROOF & ON-CHAIN LATENCY TELEMETRY", title: "1-Second Base Sepolia Settlement & 3-Second Unichain Hedge — Confirmed On-Chain", sub: "Dashboard auto-polls getLatencyStats() on Base (0xFb0d...e7ab), Lasna Sentinel (0xfF1E...7edA) & Unichain Mirror (0x48eb...453E)", cap: "Origin 0xfec6...0298 -> Lasna react() 0xd090...4518 -> Base 0xef5f...8996 (1s, OK) + Unichain 0x7f02...ccfa (3s, OK)", dur: 10.5),
    Slide(img: "\(framesDir)/02-slow-bleed-dual-freeze.png", badge: "02 · STATEFUL DECAYING SLIPPAGE SENTINEL (3x 1.90% SLOW-BLEED DEFENSE)", title: "Catches Consecutive Sub-Cap Swaps & Freezes Both Rollups Simultaneously", sub: "Single-tx 2% caps miss 3x 1.90% drain swaps; Sentinel accumulates decaying bps & fires dual SYSTEM.requestCallbackV_1_0()", cap: "Tightens Base per-swap cap 200 -> 25 bps + trips Unichain crossChainFreezeActive=true in one atomic react()", dur: 9.5),
    Slide(img: "\(framesDir)/03-keeperless-stoploss-hedge.png", badge: "03 · KEEPER-LESS SUB-SECOND STOP-LOSS & CROSS-CHAIN HEDGE FAN-OUT", title: "Zero Off-Chain Bots — Reactive Omni Matches Oracle Ticks Directly On-Chain", sub: "Order #1 ($3,000 ETH Stop-Loss) matches $2,950 tick and fans out parallel settlement + Unichain hedge callbacks", cap: "Authenticated end-to-end via reactive-lib-omni: onlySystem + onlyServiceProvider + immutable onlyCallbackSender", dur: 9.5),
    Slide(img: "\(framesDir)/04-stale-accrual-breaker.png", badge: "04 · STALE-ACCRUAL & UTILIZATION SPIKE DEFENSE + 15/15 FOUNDRY VERIFICATION", title: "Blocks Retroactive Interest Exploits & Single-Block Utilization Jumps", sub: "Solc 0.8.29 · 15/15 Foundry Tests (5x256 Fuzz Runs, 0 Warnings) · Packed uint64x4 Latency Storage (<200k Callback Gas)", cap: "Uses timestamps (not block counts) for Base Sepolia 200ms blocks · Replay-proof incidentId guard on both chains", dur: 9.5),
    Slide(img: nil, badge: "OMNIGUARD · OPEN-SOURCE MIT · LIVE ON REACTIVE OMNI LASNA + BASE + UNICHAIN", title: "Every Second Counts. Proven On-Chain.", sub: "1s Base Sepolia Callback · 3s Cross-Chain Unichain Callback · 15/15 Foundry Tests (1,280 Fuzz Runs)", cap: "GitHub: z121245017-ai/omniguard-reactive  |  Live Desk: z121245017-ai.github.io/omniguard-reactive", dur: 5.5)
]

let w = 1280, h = 720, fps: Int32 = 30
func loadImg(_ p: String) -> CGImage? {
    guard let s = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(s, 0, nil)
}
func drawText(_ ctx: CGContext, text: String, rect: CGRect, fontSize: CGFloat, weight: NSFont.Weight, color: NSColor, align: NSTextAlignment = .center, mono: Bool = false) {
    let font: NSFont = mono ? NSFont.monospacedSystemFont(ofSize: fontSize, weight: weight) : NSFont.systemFont(ofSize: fontSize, weight: weight)
    let para = NSMutableParagraphStyle(); para.alignment = align; para.lineBreakMode = .byWordWrapping
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
    NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: para]).draw(in: rect)
    NSGraphicsContext.restoreGraphicsState()
}

let outURL = URL(fileURLWithPath: outVideo)
try? FileManager.default.removeItem(at: outURL)
let writer = try AVAssetWriter(outputURL: outURL, fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 2_600_000, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel, AVVideoMaxKeyFrameIntervalKey: 60]
])
input.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA), kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h
])
writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)
guard let pool = adaptor.pixelBufferPool else { fatalError() }

func makePB(_ sl: Slide) -> CVPixelBuffer {
    var pbOut: CVPixelBuffer?; CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut); let pb = pbOut!
    CVPixelBufferLockBaseAddress(pb, []); defer { CVPixelBufferUnlockBaseAddress(pb, []) }
    let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: w, height: h, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
    ctx.setFillColor(NSColor(red: 0.031, green: 0.051, blue: 0.102, alpha: 1).cgColor); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.setFillColor(NSColor(red: 0.220, green: 0.741, blue: 0.973, alpha: 0.95).cgColor); ctx.fill(CGRect(x: 0, y: 0, width: w / 2, height: 4))
    ctx.setFillColor(NSColor(red: 0.133, green: 0.773, blue: 0.369, alpha: 0.95).cgColor); ctx.fill(CGRect(x: w / 2, y: 0, width: w / 2, height: 4))

    let green = NSColor(red: 0.204, green: 0.827, blue: 0.560, alpha: 1)
    let cyan = NSColor(red: 0.490, green: 0.827, blue: 0.988, alpha: 1)
    let whiteSoft = NSColor(red: 0.93, green: 0.95, blue: 0.98, alpha: 1)
    let muted = NSColor(red: 0.57, green: 0.65, blue: 0.76, alpha: 1)

    if let p = sl.img, let cg = loadImg(p) {
        drawText(ctx, text: sl.badge, rect: CGRect(x: 40, y: 18, width: 1200, height: 22), fontSize: 13, weight: .bold, color: cyan, mono: true)
        drawText(ctx, text: sl.title, rect: CGRect(x: 40, y: 42, width: 1200, height: 34), fontSize: 23.5, weight: .bold, color: whiteSoft)
        drawText(ctx, text: sl.sub, rect: CGRect(x: 50, y: 78, width: 1180, height: 26), fontSize: 14, weight: .regular, color: muted)

        let aspect = CGFloat(cg.width) / CGFloat(max(1, cg.height))
        let maxH: CGFloat = 516, maxW: CGFloat = 1140
        var dw = maxH * aspect, dh = maxH
        if dw > maxW { dw = maxW; dh = maxW / aspect }
        let fr = CGRect(x: (CGFloat(w) - dw) / 2, y: 114 + (maxH - dh) / 2, width: dw, height: dh)
        ctx.setStrokeColor(NSColor(red: 0.220, green: 0.741, blue: 0.973, alpha: 0.55).cgColor)
        ctx.setLineWidth(1.5); ctx.stroke(fr.insetBy(dx: -6, dy: -6))
        ctx.saveGState(); ctx.translateBy(x: fr.origin.x, y: fr.origin.y + fr.size.height); ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high; ctx.draw(cg, in: CGRect(origin: .zero, size: fr.size)); ctx.restoreGState()

        ctx.setFillColor(NSColor(red: 0.051, green: 0.086, blue: 0.145, alpha: 1).cgColor); ctx.fill(CGRect(x: 40, y: 650, width: 1200, height: 48))
        ctx.setStrokeColor(NSColor(red: 0.133, green: 0.773, blue: 0.369, alpha: 0.55).cgColor); ctx.setLineWidth(1); ctx.stroke(CGRect(x: 40, y: 650, width: 1200, height: 48))
        drawText(ctx, text: sl.cap, rect: CGRect(x: 56, y: 663, width: 1168, height: 26), fontSize: 14, weight: .semibold, color: green, mono: true)
    } else {
        let box = CGRect(x: 90, y: 140, width: 1100, height: 440)
        ctx.setFillColor(NSColor(red: 0.055, green: 0.086, blue: 0.145, alpha: 1).cgColor); ctx.fill(box)
        ctx.setStrokeColor(NSColor(red: 0.220, green: 0.741, blue: 0.973, alpha: 0.65).cgColor); ctx.setLineWidth(2); ctx.stroke(box)
        drawText(ctx, text: sl.badge, rect: CGRect(x: 120, y: 196, width: 1040, height: 28), fontSize: 15, weight: .bold, color: cyan, mono: true)
        drawText(ctx, text: sl.title, rect: CGRect(x: 120, y: 252, width: 1040, height: 76), fontSize: 56, weight: .bold, color: whiteSoft)
        drawText(ctx, text: sl.sub, rect: CGRect(x: 130, y: 348, width: 1020, height: 72), fontSize: 21, weight: .medium, color: muted)
        drawText(ctx, text: sl.cap, rect: CGRect(x: 120, y: 468, width: 1040, height: 44), fontSize: 14.5, weight: .semibold, color: green, mono: true)
    }
    return pb
}

var cur: Int64 = 0
for sl in slides {
    let pb = makePB(sl)
    let cnt = Int64(sl.dur * Double(fps))
    var off: Int64 = 0
    while off < cnt {
        while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
        adaptor.append(pb, withPresentationTime: CMTime(value: cur + off, timescale: fps))
        off += 15
    }
    cur += cnt
}
while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
adaptor.append(makePB(slides.last!), withPresentationTime: CMTime(value: cur, timescale: fps))
input.markAsFinished()
let sem = DispatchSemaphore(value: 0); writer.finishWriting { sem.signal() }; sem.wait()
let bytes = (try FileManager.default.attributesOfItem(atPath: outVideo)[.size] as? Int64) ?? 0
print(String(format: "Rendered video: %@ (%.1fs, %lld bytes)", outVideo, Double(cur)/Double(fps), bytes))
