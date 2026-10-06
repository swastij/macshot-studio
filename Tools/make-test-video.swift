// Generates a silent screen-recording-like test video (add audio with ffmpeg) with a real macOS cursor
// composited at a known path, plus a ground-truth JSON next to it.
//
//   swift Tools/make-test-video.swift <background.png> <out.mov> [scale]
//   (NO_POINTER=1 renders the same video without the pointer, as a reference)
//
// Covers: a pointer parked from the first frame, moves, clicks followed by UI
// changes, pointing-hand and I-beam shapes, a hidden stretch with typing, fast
// jumps, and a parked pointer over scrolling content.
import AppKit
import AVFoundation

_ = NSApplication.shared
let args = CommandLine.arguments
guard args.count >= 3, let bgImage = NSImage(contentsOfFile: args[1]) else {
    print("usage: make-test-video.swift <background.png> <out.mov> [scale]"); exit(1)
}
let outURL = URL(fileURLWithPath: args[2])
let scale = args.count > 3 ? CGFloat(Double(args[3]) ?? 2) : 2
let W = 1920, H = 1200, fps = 30.0, duration = 20.0
let frameCount = Int(duration * fps)

struct Key { var t: Double; var x: Double; var y: Double }
// Hotspot path in pixels, top-left origin.
let path: [Key] = [
    .init(t: 0, x: 400, y: 300), .init(t: 1.5, x: 400, y: 300), .init(t: 3.0, x: 1200, y: 500),
    .init(t: 4.0, x: 1200, y: 500), .init(t: 5.4, x: 900, y: 800), .init(t: 6.0, x: 900, y: 800),
    .init(t: 7.6, x: 700, y: 640), .init(t: 10.0, x: 700, y: 640), .init(t: 10.4, x: 1700, y: 200),
    .init(t: 10.8, x: 200, y: 1000), .init(t: 11.4, x: 1500, y: 900), .init(t: 12.0, x: 1000, y: 400),
    .init(t: 14.0, x: 1000, y: 400), .init(t: 15.3, x: 600, y: 200), .init(t: 16.5, x: 600, y: 200),
    .init(t: 17.8, x: 1400, y: 700), .init(t: 20.0, x: 1400, y: 700),
]
let clicks: [Double] = [3.2, 5.6, 15.5, 17.95]
let hidden = 8.0..<10.0
func position(_ t: Double) -> (Double, Double) {
    for i in 0..<(path.count - 1) where t >= path[i].t && t <= path[i + 1].t {
        let a = path[i], b = path[i + 1]
        var f = (t - a.t) / max(1e-9, b.t - a.t)
        f = f * f * (3 - 2 * f)
        return (a.x + (b.x - a.x) * f, a.y + (b.y - a.y) * f)
    }
    return (path.last!.x, path.last!.y)
}
func shape(_ t: Double) -> NSCursor {
    if t >= 5.0 && t < 6.0 { return .pointingHand }
    if t >= 6.0 && t < 8.0 { return .iBeam }
    return .arrow
}

func cg(_ cursor: NSCursor) -> CGImage {
    // Cursor images may be vector; rasterize at 8x for a sharp downscale.
    let size = cursor.image.size
    let w = Int(size.width * 8), h = Int(size.height * 8)
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    cursor.image.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
    NSGraphicsContext.restoreGraphicsState()
    return ctx.makeImage()!
}
var bgRect = CGRect(origin: .zero, size: bgImage.size)
let bg = bgImage.cgImage(forProposedRect: &bgRect, context: nil, hints: nil)!

try? FileManager.default.removeItem(at: outURL)
let writer = try! AVAssetWriter(outputURL: outURL, fileType: .mov)
let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: W, AVVideoHeightKey: H,
    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000],
])
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: W,
    kCVPixelBufferHeightKey as String: H,
])
writer.add(vIn)
writer.startWriting(); writer.startSession(atSourceTime: .zero)

func checkWriter() {
    if writer.status == .failed { print("writer failed: \(String(describing: writer.error))"); exit(2) }
}

var truth: [[String: Any]] = []
let space = CGColorSpace(name: CGColorSpace.sRGB)!
for i in 0..<frameCount {
    let t = Double(i) / fps
    var pb: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
    let buffer = pb!
    CVPixelBufferLockBaseAddress(buffer, [])
    let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: W, height: H, bitsPerComponent: 8,
                        bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    // Background, scrolling between 12 and 14 s.
    let scroll = t >= 12 && t < 14 ? (t - 12) * 300 : (t >= 14 ? 600 : 0)
    ctx.draw(bg, in: CGRect(x: 0, y: CGFloat(scroll) - 600, width: CGFloat(W), height: CGFloat(H) + 600))
    // UI reactions to clicks: a highlight box that appears 150 ms later.
    for (n, c) in clicks.enumerated() where t >= c + 0.15 {
        let (cx, cy) = position(c)
        ctx.setFillColor(NSColor.systemBlue.withAlphaComponent(0.35).cgColor)
        ctx.fill(CGRect(x: cx - 120 + Double(n) * 7, y: Double(H) - cy - 60, width: 240, height: 90))
    }
    // "Typing": text grows while the pointer is hidden.
    if t >= hidden.lowerBound {
        let chars = Int((min(t, hidden.upperBound) - hidden.lowerBound) / 0.2)
        let text = String(repeating: "typing ", count: 20).prefix(chars) as Substring
        let attr = NSAttributedString(string: String(text), attributes: [.font: NSFont.systemFont(ofSize: 28),
                                                                          .foregroundColor: NSColor.black])
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSColor.white.setFill(); NSRect(x: 680, y: Double(H) - 700, width: 560, height: 44).fill()
        attr.draw(at: NSPoint(x: 690, y: Double(H) - 694))
        NSGraphicsContext.restoreGraphicsState()
    }
    let (x, y) = position(t)
    let visible = !hidden.contains(t)
    let drawPointer = visible && ProcessInfo.processInfo.environment["NO_POINTER"] == nil
    let cursor = shape(t)
    if drawPointer {
        let img = cg(cursor)
        let size = cursor.image.size
        let hs = cursor.hotSpot
        let rect = CGRect(x: x - hs.x * scale, y: Double(H) - (y - hs.y * scale) - size.height * scale,
                          width: size.width * scale, height: size.height * scale)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1.5 * scale), blur: 3 * scale,
                      color: NSColor.black.withAlphaComponent(0.45).cgColor)
        ctx.interpolationQuality = .high
        ctx.draw(img, in: rect)
        ctx.restoreGState()
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    while !vIn.isReadyForMoreMediaData { checkWriter(); usleep(1000) }
    adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
    let name = cursor == .arrow ? "arrow" : cursor == .iBeam ? "iBeam" : "pointingHand"
    truth.append(["t": t, "x": x, "y": y, "visible": visible, "shape": name])
}
vIn.markAsFinished()

let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
let truthURL = outURL.deletingPathExtension().appendingPathExtension("truth.json")
let json = try! JSONSerialization.data(withJSONObject: ["scale": scale, "clicks": clicks, "frames": truth])
try! json.write(to: truthURL)
print("wrote \(outURL.path) (\(writer.status == .completed ? "ok" : "\(String(describing: writer.error))")) and \(truthURL.lastPathComponent)")
