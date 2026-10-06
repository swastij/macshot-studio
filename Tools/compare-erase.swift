// Measures how well a cleaned video removed the pointer, against a reference
// rendered without one (make-test-video with NO_POINTER=1).
//
//   swift Tools/compare-erase.swift <original> <cleaned> <reference> <truth.json>
//
// Reports the mean luma difference from the reference inside the pointer's
// box (original = how visible the pointer was; cleaned = what is left of it)
// and across the rest of the frame (re-encoding loss).
import AVFoundation

let a = CommandLine.arguments
let truth = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: a[4]))) as! [String: Any]
let frames = truth["frames"] as! [[String: Any]]
let scale = truth["scale"] as! Double

func reader(_ path: String) -> AVAssetReaderTrackOutput {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    let r = try! AVAssetReader(asset: asset)
    let out = AVAssetReaderTrackOutput(track: asset.tracks(withMediaType: .video)[0], outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange])
    r.add(out); r.startReading()
    objc_setAssociatedObject(out, "r", r, .OBJC_ASSOCIATION_RETAIN)
    return out
}
let outs = [reader(a[1]), reader(a[2]), reader(a[3])]
var segments: [String: (n: Int, orig: Double, clean: Double, worst: Double, worstT: Double)] = [:]
var rest = 0.0, restN = 0
var i = 0
while let s0 = outs[0].copyNextSampleBuffer(), let s1 = outs[1].copyNextSampleBuffer(), let s2 = outs[2].copyNextSampleBuffer() {
    defer { i += 1 }
    guard i < frames.count else { break }
    let f = frames[i]
    let bufs = [s0, s1, s2].map { CMSampleBufferGetImageBuffer($0)! }
    bufs.forEach { CVPixelBufferLockBaseAddress($0, .readOnly) }
    defer { bufs.forEach { CVPixelBufferUnlockBaseAddress($0, .readOnly) } }
    let p = bufs.map { CVPixelBufferGetBaseAddressOfPlane($0, 0)!.assumingMemoryBound(to: UInt8.self) }
    let rb = bufs.map { CVPixelBufferGetBytesPerRowOfPlane($0, 0) }
    let w = CVPixelBufferGetWidthOfPlane(bufs[0], 0), h = CVPixelBufferGetHeightOfPlane(bufs[0], 0)
    let x = f["x"] as! Double, y = f["y"] as! Double
    let x0 = max(0, Int(x - 14 * scale)), x1 = min(w - 1, Int(x + 30 * scale))
    let y0 = max(0, Int(y - 14 * scale)), y1 = min(h - 1, Int(y + 42 * scale))
    var orig = 0.0, clean = 0.0, n = 0
    for yy in y0...y1 { for xx in x0...x1 {
        let r = Double(p[2][yy * rb[2] + xx])
        orig += abs(Double(p[0][yy * rb[0] + xx]) - r)
        clean += abs(Double(p[1][yy * rb[1] + xx]) - r)
        n += 1
    } }
    for yy in stride(from: 0, to: h, by: 7) { for xx in stride(from: 0, to: w, by: 7) where !(xx >= x0 && xx <= x1 && yy >= y0 && yy <= y1) {
        rest += abs(Double(p[1][yy * rb[1] + xx]) - Double(p[2][yy * rb[2] + xx])); restN += 1
    } }
    let t = f["t"] as! Double
    let seg = (f["visible"] as! Bool) ? (t >= 12 && t < 14 ? "parked over scrolling" : f["shape"] as! String) : "hidden"
    var e = segments[seg] ?? (0, 0, 0, 0, 0)
    let c = clean / Double(n)
    e.n += 1; e.orig += orig / Double(n); e.clean += c
    if c > e.worst { e.worst = c; e.worstT = t }
    if ProcessInfo.processInfo.environment["VERBOSE"] != nil, c > 3 { print(String(format: "  %.2fs %@ cleaned %.1f original %.1f", t, seg, c, orig / Double(n))) }
    segments[seg] = e
}
print("mean luma difference from the pointer-free reference (0-255):")
for (k, e) in segments.sorted(by: { $0.key < $1.key }) {
    print(String(format: "  %-22@ frames %3d  pointer box: original %5.2f -> cleaned %5.2f (worst %5.2f at %.2fs)",
                 k as NSString, e.n, e.orig / Double(e.n), e.clean / Double(e.n), e.worst, e.worstT))
}
print(String(format: "  rest of frame (re-encode loss): %.2f", rest / Double(restN)))
