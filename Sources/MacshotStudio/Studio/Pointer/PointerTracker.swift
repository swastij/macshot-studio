import AVFoundation
import CoreVideo

/// One analysed video frame.
nonisolated struct PointerFrame: Codable, Sendable {
    var time: Double
    var visible: Bool
    /// Hotspot in decoded-frame pixels (top-left origin). Holds the last known
    /// position while the pointer is hidden.
    var x: Float
    var y: Float
    var kind: UInt8
    var score: Int32
    /// Share of sampled pixels that changed since the previous frame, outside
    /// the pointer, across the frame and near the pointer.
    var globalChange: Float
    var localChange: Float
}

nonisolated struct PointerTrack: Sendable {
    var frames: [PointerFrame]
    /// Video pixels per cursor point.
    var scale: CGFloat
    /// Decoded (pre-transform) frame size.
    var width: Int
    var height: Int
    var transform: CGAffineTransform
    var frameRate: Double
    var foundFraction: Double
}

nonisolated enum PointerAnalysisError: LocalizedError {
    case noVideo
    case pointerNotFound
    case readFailed(String)

    var errorDescription: String? {
        switch self {
        case .noVideo: return "This file has no video track."
        case .pointerNotFound: return "Couldn't find a macOS pointer in this video."
        case .readFailed(let reason): return "Couldn't read the video: \(reason)"
        }
    }
}

/// Finds the system pointer in every frame by template matching, searching
/// only where the screen changed: the pointer is the thing that moves, while
/// pointer-like icons in the content stay put.
nonisolated enum PointerTracker {
    /// Scales tried when calibrating (video pixels per point).
    static let scaleGrid: [CGFloat] = stride(from: 0.75, through: 3.5, by: 0.0625).map { CGFloat($0) }
    static let calibrationSamples = 32
    static let debug = ProcessInfo.processInfo.environment["STUDIO_DEBUG"] != nil
    static let cell = 8

    static func track(asset: AVAsset, templates: [CGFloat: [PointerTemplate]],
                      cancellation: MediaExportCancellation,
                      progress: @escaping @Sendable (Double) -> Void) async throws -> PointerTrack {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw PointerAnalysisError.noVideo }
        let (duration, transform, nominalRate) = try await (asset.load(.duration), track.load(.preferredTransform),
                                                            track.load(.nominalFrameRate))
        let seconds = duration.seconds
        guard seconds.isFinite, seconds > 0 else { throw PointerAnalysisError.noVideo }

        let scale = try calibrate(asset: asset, track: track, duration: seconds, templates: templates,
                                  cancellation: cancellation)
        progress(0.05)
        guard let chosen = templates[scale] else { throw PointerAnalysisError.pointerNotFound }
        var result = try trackFrames(asset: asset, track: track, duration: seconds, templates: chosen, scale: scale,
                                     cancellation: cancellation) { progress(0.05 + 0.95 * $0) }
        result.transform = transform
        if result.frameRate <= 0 { result.frameRate = Double(nominalRate > 0 ? nominalRate : 30) }
        return result
    }

    // MARK: Calibration

    /// Picks the cursor scale from pairs of consecutive frames: at the right
    /// scale the pointer is found, where the frames differ, in the most pairs.
    private static func calibrate(asset: AVAsset, track: AVAssetTrack, duration: Double,
                                  templates: [CGFloat: [PointerTemplate]],
                                  cancellation: MediaExportCancellation) throws -> CGFloat {
        struct Sample { var luma: OwnedLuma; var changed: [Bool]; var cols: Int; var rows: Int }
        var samples: [Sample] = []
        for k in 0..<calibrationSamples {
            try cancellation.check()
            let t = duration * (0.02 + 0.96 * Double(k) / Double(calibrationSamples - 1))
            guard let (a, b) = try? readLumaPair(asset: asset, track: track, at: t) else { continue }
            let (changed, cols, rows) = changedCells(a, b)
            guard changed.contains(true) else { continue }
            samples.append(Sample(luma: b, changed: changed, cols: cols, rows: rows))
        }
        guard !samples.isEmpty else { throw PointerAnalysisError.pointerNotFound }

        func evaluate(_ scale: CGFloat) -> (found: Int, mean: Double, hits: [(Int, PointerMatch)]) {
            guard let set = templates[scale] else { return (0, .infinity, []) }
            let acquisition = set.indices.filter { PointerKind.acquisition.contains(set[$0].kind) }
            let grow = (set.map { max($0.width, $0.height) }.max() ?? 32) / cell + 1
            var hits: [(Int, PointerMatch)] = []
            var total = 0.0
            for (i, sample) in samples.enumerated() {
                let mask = CellMask(changed: sample.changed, cols: sample.cols, rows: sample.rows, step: cell, grow: grow)
                guard mask.fraction < 0.5 else { continue }  // scrolling/cuts: no pointer evidence
                let matcher = PointerMatcher(templates: set, rowBytes: sample.luma.width)
                if let m = sample.luma.withFrame({ matcher.search($0, candidates: acquisition, cells: mask) }) {
                    hits.append((i, m))
                    total += Double(m.score) / 16
                }
            }
            return (hits.count, hits.isEmpty ? .infinity : total / Double(hits.count), hits)
        }

        // Among scales that find the pointer about as often as the best one,
        // the closest fit wins (a smaller cursor can partly fit inside a
        // bigger one, but never as well).
        let coarse = scaleGrid.enumerated().filter { $0.offset % 4 == 0 }.map(\.element)
        var results: [(scale: CGFloat, found: Int, mean: Double, hits: [(Int, PointerMatch)])] = []
        for scale in coarse {
            try cancellation.check()
            let r = evaluate(scale)
            if debug { print("calibrate \(scale): found \(r.found)/\(samples.count) mean \(r.mean)") }
            if r.found > 0 { results.append((scale, r.found, r.mean, r.hits)) }
        }
        let mostFound = results.map(\.found).max() ?? 0
        guard let coarseBest = results.filter({ Double($0.found) >= 0.6 * Double(mostFound) }).min(by: { $0.mean < $1.mean })
        else { throw PointerAnalysisError.pointerNotFound }

        // Refine in 1/16 steps: the right scale fits those pointers most closely.
        var best = (scale: coarseBest.scale, mean: Double.infinity)
        for scale in scaleGrid where abs(scale - coarseBest.scale) <= 0.32 {
            guard let set = templates[scale] else { continue }
            let acquisition = set.indices.filter { PointerKind.acquisition.contains(set[$0].kind) }
            var total = 0.0
            for (i, hit) in coarseBest.hits {
                let luma = samples[i].luma
                let matcher = PointerMatcher(templates: set, rowBytes: luma.width)
                let r = Int(6 * scale)
                let m = luma.withFrame {
                    matcher.search($0, candidates: acquisition, x0: hit.x - r, y0: hit.y - r, x1: hit.x + r, y1: hit.y + r,
                                   step: 1, limit: PointerMatcher.threshold * 2)
                }
                total += Double(m?.score ?? PointerMatcher.threshold * 32) / 16
            }
            let mean = total / Double(max(1, coarseBest.hits.count))
            if debug { print("refine \(scale): mean \(mean)") }
            if mean < best.mean { best = (scale, mean) }
        }
        return best.scale
    }

    // MARK: Tracking pass

    private static func trackFrames(asset: AVAsset, track: AVAssetTrack, duration: Double,
                                    templates: [PointerTemplate], scale: CGFloat,
                                    cancellation: MediaExportCancellation,
                                    progress: @Sendable (Double) -> Void) throws -> PointerTrack {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw PointerAnalysisError.readFailed(reader.error?.localizedDescription ?? "unknown error")
        }
        defer { if reader.status == .reading { reader.cancelReading() } }

        let all = Array(templates.indices)
        let acquisition = all.filter { PointerKind.acquisition.contains(templates[$0].kind) }
        /// Every phase variant of each shape.
        let variants = Dictionary(grouping: all, by: { templates[$0].kind })
        var lostSince: Double?
        let grow = (templates.map { max($0.width, $0.height) }.max() ?? 32) / cell + 1
        let s = Double(scale)
        var matcher: PointerMatcher?
        var frames: [PointerFrame] = []
        var last: PointerMatch?
        var lastKnown: PointerMatch?
        var velocity = (x: 0.0, y: 0.0)
        var stillFrames = 0
        var foundCount = 0
        var meter = ChangeMeter(scale: scale)
        var lastProgress = 0.0
        var previousFrame: [UInt8] = []

        while let sample = output.copyNextSampleBuffer() {
            try cancellation.check()
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { continue }
            let frame = LumaFrame(base: base.assumingMemoryBound(to: UInt8.self),
                                  rowBytes: CVPixelBufferGetBytesPerRowOfPlane(buffer, 0),
                                  width: CVPixelBufferGetWidthOfPlane(buffer, 0),
                                  height: CVPixelBufferGetHeightOfPlane(buffer, 0))
            if matcher?.rowBytes != frame.rowBytes { matcher = PointerMatcher(templates: templates, rowBytes: frame.rowBytes) }
            let m = matcher!
            meter.advance(frame)
            let changedMask = { (zone: Zone?) in
                CellMask(changed: meter.changed, cols: meter.cols, rows: meter.rows, step: cell, grow: grow, within: zone)
            }

            var found: PointerMatch?
            if let prev = last {
                // Still there (or nudged)? Re-check the same shape first.
                found = m.search(frame, candidates: variants[templates[prev.templateIndex].kind] ?? [prev.templateIndex],
                                 x0: prev.x - 2, y0: prev.y - 2, x1: prev.x + 2, y1: prev.y + 2, step: 1)
                if found == nil {
                    // Moved or changed shape: search where the screen changed
                    // within reach of the last position.
                    let speed = (velocity.x * velocity.x + velocity.y * velocity.y).squareRoot()
                    let r = Int(min(220 * s, max(40 * s, speed * 2.5 + 30 * s)))
                    let px = prev.x + Int(velocity.x), py = prev.y + Int(velocity.y)
                    let zone = Zone(x0: min(px, prev.x) - r, y0: min(py, prev.y) - r,
                                    x1: max(px, prev.x) + r, y1: max(py, prev.y) + r)
                    found = m.search(frame, candidates: all, cells: changedMask(zone))
                }
                if let f = found, f.x == prev.x, f.y == prev.y {
                    stillFrames += 1
                } else {
                    stillFrames = 0
                }
                // Parked on something while a pointer-shaped thing moves
                // elsewhere? Then we were holding on to artwork.
                if let f = found, stillFrames >= 8, meter.changedCount > 0 {
                    let mask = changedMask(nil)
                    if mask.fraction < 0.3,
                       let other = m.search(frame, candidates: acquisition, cells: mask,
                                            excluding: [Zone(around: f.x, f.y, radius: Int(10 * s))]),
                       other.score + m.penalty[other.templateIndex] <= f.score + m.penalty[f.templateIndex] + 3 * 16 {
                        found = other
                        stillFrames = 0
                    }
                }
            }
            if found == nil, let known = lastKnown, let since = lostSince, time - since < 1.0 {
                // Just lost: any shape, near where it was.
                let r = Int(60 * s)
                found = m.search(frame, candidates: all, x0: known.x - r, y0: known.y - r, x1: known.x + r, y1: known.y + r,
                                 step: 2)
            }
            if found == nil, meter.changedCount > 0 {
                // Lost: the pointer reappears or starts moving where the screen changes.
                let mask = changedMask(nil)
                if mask.fraction < 0.6, let f = m.search(frame, candidates: acquisition, cells: mask) {
                    found = f
                    // If it just started moving, the previous frame shows where
                    // it was parked; it sat there through the quiet frames before.
                    if !previousFrame.isEmpty, let parked = previousFrame.withUnsafeBufferPointer({ buf in
                        m.search(LumaFrame(base: buf.baseAddress!, rowBytes: frame.rowBytes, width: frame.width, height: frame.height),
                                 candidates: acquisition, cells: mask)
                    }) {
                        var k = frames.count - 1
                        while k >= 0, !frames[k].visible, frames[k].globalChange < 0.01 || k == frames.count - 1 {
                            frames[k].visible = true
                            frames[k].x = Float(parked.x); frames[k].y = Float(parked.y)
                            frames[k].kind = templates[parked.templateIndex].kind.rawValue
                            frames[k].score = parked.score
                            k -= 1
                        }
                    }
                }
            }

            if let f = found {
                if let prev = last {
                    velocity = (0.6 * Double(f.x - prev.x) + 0.4 * velocity.x, 0.6 * Double(f.y - prev.y) + 0.4 * velocity.y)
                } else {
                    velocity = (0, 0)
                }
                last = f
                lastKnown = f
                lostSince = nil
                foundCount += 1
            } else {
                if last != nil { lostSince = time }
                last = nil
                velocity = (0, 0)
                stillFrames = 0
            }

            let anchor = found ?? lastKnown
            let template = anchor.map { templates[$0.templateIndex] }
            let metrics = meter.metrics(visible: found.map { ($0.x, $0.y) }, center: anchor.map { ($0.x, $0.y) },
                                        pointerSize: template.map { ($0.width, $0.height) })
            frames.append(PointerFrame(time: time, visible: found != nil,
                                       x: Float(anchor?.x ?? 0), y: Float(anchor?.y ?? 0),
                                       kind: template?.kind.rawValue ?? 0, score: found?.score ?? .max,
                                       globalChange: metrics.global, localChange: metrics.local))
            let fraction = min(1, max(0, time / duration))
            if fraction - lastProgress > 0.01 { progress(fraction); lastProgress = fraction }
            let planeBytes = frame.rowBytes * frame.height
            if previousFrame.count != planeBytes { previousFrame = [UInt8](repeating: 0, count: planeBytes) }
            previousFrame.withUnsafeMutableBufferPointer { _ = memcpy($0.baseAddress!, frame.base, planeBytes) }
        }
        if reader.status == .failed {
            throw PointerAnalysisError.readFailed(reader.error?.localizedDescription ?? "unknown error")
        }
        guard foundCount > 0, let first = frames.first else { throw PointerAnalysisError.pointerNotFound }
        bridgeGaps(&frames, scale: scale)
        backfill(&frames)
        let span = (frames.last?.time ?? 0) - first.time
        let rate = frames.count > 1 && span > 0 ? Double(frames.count - 1) / span : 0
        return PointerTrack(frames: frames, scale: scale, width: meter.width, height: meter.height, transform: .identity,
                            frameRate: rate, foundFraction: Double(foundCount) / Double(frames.count))
    }

    /// A few missed frames between two sightings are a detection hiccup, not
    /// the pointer hiding: interpolate them so the pointer doesn't flicker.
    private static func bridgeGaps(_ frames: inout [PointerFrame], scale: CGFloat) {
        let maxGap = 8
        let maxStep = Float(120 * scale)  // pixels per frame
        var i = 0
        while i < frames.count {
            guard !frames[i].visible, i > 0, frames[i - 1].visible else { i += 1; continue }
            var j = i
            while j < frames.count, !frames[j].visible { j += 1 }
            let gap = j - i
            if j < frames.count, gap <= maxGap {
                let a = frames[i - 1], b = frames[j]
                let dx = b.x - a.x, dy = b.y - a.y
                if (dx * dx + dy * dy).squareRoot() <= maxStep * Float(gap + 1) {
                    for k in i..<j {
                        let t = Float(k - i + 1) / Float(gap + 1)
                        frames[k].visible = true
                        frames[k].x = (a.x + dx * t).rounded()
                        frames[k].y = (a.y + dy * t).rounded()
                        frames[k].kind = t < 0.5 ? a.kind : b.kind
                        frames[k].score = max(a.score, b.score)
                    }
                }
            }
            i = j
        }
    }

    /// Frames before the first sighting take its position (still hidden),
    /// so zooms there have a sensible center.
    private static func backfill(_ frames: inout [PointerFrame]) {
        guard let firstSeen = frames.firstIndex(where: \.visible) else { return }
        for i in 0..<firstSeen {
            frames[i].x = frames[firstSeen].x
            frames[i].y = frames[firstSeen].y
            frames[i].kind = frames[firstSeen].kind
        }
    }

    // MARK: Frame access

    /// A decoded luma plane copied out of the decoder's buffer.
    struct OwnedLuma {
        var pixels: [UInt8]
        var width: Int
        var height: Int
        func withFrame<T>(_ body: (LumaFrame) -> T) -> T {
            pixels.withUnsafeBufferPointer { body(LumaFrame(base: $0.baseAddress!, rowBytes: width, width: width, height: height)) }
        }
    }

    static func readLuma(asset: AVAsset, track: AVAssetTrack, at seconds: Double) throws -> OwnedLuma? {
        try readLumaFrames(asset: asset, track: track, at: seconds, count: 1).first
    }

    /// Two consecutive decoded frames starting at `seconds`.
    static func readLumaPair(asset: AVAsset, track: AVAssetTrack, at seconds: Double) throws -> (OwnedLuma, OwnedLuma)? {
        let frames = try readLumaFrames(asset: asset, track: track, at: seconds, count: 2)
        return frames.count == 2 ? (frames[0], frames[1]) : nil
    }

    private static func readLumaFrames(asset: AVAsset, track: AVAssetTrack, at seconds: Double, count: Int) throws -> [OwnedLuma] {
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: seconds, preferredTimescale: 600),
                                       duration: CMTime(seconds: 1, preferredTimescale: 600))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        ])
        reader.add(output)
        guard reader.startReading() else { return [] }
        defer { reader.cancelReading() }
        var result: [OwnedLuma] = []
        while result.count < count, let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { continue }
            let width = CVPixelBufferGetWidthOfPlane(buffer, 0), height = CVPixelBufferGetHeightOfPlane(buffer, 0)
            let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            var pixels = [UInt8](repeating: 0, count: width * height)
            pixels.withUnsafeMutableBufferPointer { dst in
                for y in 0..<height { memcpy(dst.baseAddress! + y * width, base + y * rowBytes, width) }
            }
            result.append(OwnedLuma(pixels: pixels, width: width, height: height))
        }
        return result
    }

    /// Changed cells between two frames (any sampled pixel moved).
    static func changedCells(_ a: OwnedLuma, _ b: OwnedLuma) -> ([Bool], Int, Int) {
        let cols = b.width / cell, rows = b.height / cell
        var changed = [Bool](repeating: false, count: cols * rows)
        guard a.width == b.width, a.height == b.height else { return (changed, cols, rows) }
        for r in 0..<rows {
            for c in 0..<cols {
                for (dx, dy) in ChangeMeter.offsets {
                    let i = (r * cell + dy) * b.width + c * cell + dx
                    if abs(Int(a.pixels[i]) - Int(b.pixels[i])) > ChangeMeter.delta { changed[r * cols + c] = true; break }
                }
            }
        }
        return (changed, cols, rows)
    }
}

/// Per-cell change between consecutive frames, and the screen-change
/// measures click inference uses (which ignore the pointer itself).
nonisolated struct ChangeMeter {
    static let delta: Int32 = 16
    /// Every other pixel of a cell, so thin strokes (a typed letter) register.
    static let offsets: [(Int, Int)] = stride(from: 1, to: 8, by: 2).flatMap { y in stride(from: 1, to: 8, by: 2).map { ($0, y) } }
    private var previous: [UInt8] = []
    private var previousPointer: (Int, Int)?
    private let localRadius: Int
    private let scale: CGFloat
    private(set) var cols = 0
    private(set) var rows = 0
    private(set) var width = 0
    private(set) var height = 0
    /// Cells with any changed sample since the previous frame.
    private(set) var changed: [Bool] = []
    private(set) var changedCount = 0

    init(scale: CGFloat) {
        self.scale = scale
        localRadius = Int(160 * scale)
    }

    mutating func advance(_ frame: LumaFrame) {
        let step = PointerTracker.cell
        cols = frame.width / step
        rows = frame.height / step
        width = frame.width
        height = frame.height
        let n = Self.offsets.count
        var grid = [UInt8](repeating: 0, count: cols * rows * n)
        for r in 0..<rows {
            for c in 0..<cols {
                for (k, o) in Self.offsets.enumerated() {
                    grid[(r * cols + c) * n + k] = frame.base[(r * step + o.1) * frame.rowBytes + c * step + o.0]
                }
            }
        }
        changed = [Bool](repeating: false, count: cols * rows)
        changedCount = 0
        if previous.count == grid.count {
            for i in 0..<(cols * rows) {
                for k in 0..<n where abs(Int32(grid[i * n + k]) - Int32(previous[i * n + k])) > Self.delta {
                    changed[i] = true
                    changedCount += 1
                    break
                }
            }
        }
        previous = grid
    }

    /// Share of cells that changed, across the frame and near the pointer
    /// (`center`, its last known spot), leaving out the cells a visible
    /// pointer covers now or covered before.
    mutating func metrics(visible pointerNow: (Int, Int)?, center pointer: (Int, Int)?,
                          pointerSize: (Int, Int)?) -> (global: Float, local: Float) {
        defer { previousPointer = pointerNow }
        let step = PointerTracker.cell
        let pad = Int(8 * scale)
        let (pw, ph) = pointerSize ?? (Int(32 * scale), Int(32 * scale))
        let boxes = [pointerNow, previousPointer].compactMap { $0 }
            .map { Zone(x0: $0.0 - pw - pad, y0: $0.1 - ph - pad, x1: $0.0 + pw + pad, y1: $0.1 + ph + pad) }
        var changedTotal = 0, counted = 0, localChanged = 0, localCounted = 0
        let r2 = localRadius * localRadius
        for r in 0..<rows {
            for c in 0..<cols {
                let x = c * step + step / 2, y = r * step + step / 2
                if boxes.contains(where: { $0.contains(x, y) }) { continue }
                let moved = changed[r * cols + c]
                counted += 1
                if moved { changedTotal += 1 }
                if let p = pointer {
                    let dx = x - p.0, dy = y - p.1
                    if dx * dx + dy * dy <= r2 {
                        localCounted += 1
                        if moved { localChanged += 1 }
                    }
                }
            }
        }
        return (counted > 0 ? Float(changedTotal) / Float(counted) : 0,
                localCounted > 0 ? Float(localChanged) / Float(localCounted) : 0)
    }
}
