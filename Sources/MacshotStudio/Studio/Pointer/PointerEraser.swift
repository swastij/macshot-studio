import AVFoundation
import CoreVideo

/// Writes a copy of the video with the baked-in pointer painted out, so the
/// editor can draw its own restyleable pointer on top.
///
/// Each pointer box is filled from the last time those pixels were visible,
/// if nothing around it changed since. Otherwise (say a click changed the UI
/// under a resting pointer) it is filled from when those pixels are next
/// revealed, if nothing changes until then. Content changing under a parked
/// pointer (scrolling, playback) gets a smooth blend from the surroundings.
nonisolated enum PointerEraser {
    struct Box: Hashable, Sendable { var x0: Int; var y0: Int; var x1: Int; var y1: Int }  // inclusive

    static func erase(asset: AVAsset, track: PointerTrack, templates: [PointerTemplate], to outputURL: URL,
                      cancellation: MediaExportCancellation, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else { throw PointerAnalysisError.noVideo }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let duration = try await asset.load(.duration).seconds
        let transform = try await videoTrack.load(.preferredTransform)
        let formats = try await videoTrack.load(.formatDescriptions)
        var audioFormats: [CMFormatDescription?] = []
        for a in audioTracks { audioFormats.append(try await a.load(.formatDescriptions).first) }

        let width = track.width, height = track.height
        let boxes = makeBoxes(track: track, templates: templates)
        let times = track.frames.map(\.time)

        try? FileManager.default.removeItem(at: outputURL)
        let reader = try AVAssetReader(asset: asset)
        let videoOut = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        videoOut.alwaysCopiesSampleData = false
        reader.add(videoOut)
        let audioOuts = audioTracks.map { AVAssetReaderTrackOutput(track: $0, outputSettings: nil) }
        audioOuts.forEach { reader.add($0) }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        var compression: [String: Any] = [AVVideoQualityKey: 0.9, AVVideoExpectedSourceFrameRateKey: Int(track.frameRate.rounded())]
        compression[AVVideoAllowFrameReorderingKey] = true
        var videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression,
        ]
        if let color = colorProperties(formats.first) { videoSettings[AVVideoColorPropertiesKey] = color }
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoIn.transform = transform
        videoIn.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoIn, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(videoIn)
        let audioIns = zip(audioTracks, audioFormats).map { _, format in
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: format)
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            return input
        }

        let exclusionPad = Int((2 * track.scale).rounded(.up))
        let plan = try planFills(asset: asset, track: videoTrack, boxes: boxes, times: times, width: width, height: height,
                                 pad: exclusionPad, cancellation: cancellation) { progress(0.4 * $0) }
        let state = EraseState(width: width, height: height, pad: exclusionPad)

        guard reader.startReading() else { throw PointerAnalysisError.readFailed(reader.error?.localizedDescription ?? "unknown") }
        guard writer.startWriting() else { throw PointerAnalysisError.readFailed(writer.error?.localizedDescription ?? "unknown") }
        writer.startSession(atSourceTime: .zero)

        let group = DispatchGroup()
        let failure = FailureBox()
        group.enter()
        let videoQueue = DispatchQueue(label: "studio.erase.video")
        var finished = false
        var lastProgress = 0.0
        videoIn.requestMediaDataWhenReady(on: videoQueue) {
            while videoIn.isReadyForMoreMediaData && !finished {
                if cancellation.isCancelled { failure.set(CancellationError()) }
                guard failure.error == nil, let sample = videoOut.copyNextSampleBuffer(),
                      let source = CMSampleBufferGetImageBuffer(sample) else {
                    finished = true
                    videoIn.markAsFinished()
                    group.leave()
                    return
                }
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                let index = nearestIndex(times, pts.seconds)
                guard let pool = adaptor.pixelBufferPool else { failure.set(PointerAnalysisError.readFailed("no pixel buffer pool")); continue }
                var out: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
                guard let destination = out else { failure.set(PointerAnalysisError.readFailed("out of memory")); continue }
                state.process(source: source, destination: destination, frame: index,
                              box: index.flatMap { boxes[$0] }, previousBox: index.flatMap { $0 > 0 ? boxes[$0 - 1] : nil },
                              plan: plan)
                CVBufferPropagateAttachments(source, destination)
                if !adaptor.append(destination, withPresentationTime: pts) {
                    failure.set(writer.error ?? PointerAnalysisError.readFailed("could not write frame"))
                }
                let fraction = duration > 0 ? pts.seconds / duration : 0
                if fraction - lastProgress > 0.01 { progress(0.4 + 0.6 * min(1, fraction)); lastProgress = fraction }
            }
        }
        for (output, input) in zip(audioOuts, audioIns) {
            group.enter()
            var done = false
            input.requestMediaDataWhenReady(on: DispatchQueue(label: "studio.erase.audio")) {
                while input.isReadyForMoreMediaData && !done {
                    guard failure.error == nil, let sample = output.copyNextSampleBuffer() else {
                        done = true
                        input.markAsFinished()
                        group.leave()
                        return
                    }
                    if !input.append(sample) { failure.set(writer.error ?? PointerAnalysisError.readFailed("could not write audio")) }
                }
            }
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in group.notify(queue: .global()) { c.resume() } }

        if let error = failure.error ?? (reader.status == .failed ? reader.error : nil) {
            reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
        await writer.finishWriting()
        if writer.status != .completed {
            throw PointerAnalysisError.readFailed(writer.error?.localizedDescription ?? "could not finish the file")
        }
    }

    // MARK: Boxes

    /// The region each frame's pointer (with its shadow) covers.
    static func makeBoxes(track: PointerTrack, templates: [PointerTemplate]) -> [Box?] {
        let s = track.scale
        let byKind = Dictionary(templates.map { ($0.kind.rawValue, $0) }, uniquingKeysWith: { a, _ in a })
        // The macOS pointer shadow is a ~3 pt blur offset slightly downward.
        let left = Int((4 * s).rounded(.up)), top = Int((4 * s).rounded(.up))
        let right = Int((5 * s).rounded(.up)), bottom = Int((7 * s).rounded(.up))
        return track.frames.map { f in
            guard f.visible, let t = byKind[f.kind] else { return nil }
            let ox = Int(f.x) - t.hotspotX, oy = Int(f.y) - t.hotspotY
            let box = Box(x0: max(0, ox - left), y0: max(0, oy - top),
                          x1: min(track.width - 1, ox + t.width - 1 + right),
                          y1: min(track.height - 1, oy + t.height - 1 + bottom))
            return box.x0 <= box.x1 && box.y0 <= box.y1 ? box : nil
        }
    }

    static func intersects(_ a: Box, _ b: Box) -> Bool { a.x0 <= b.x1 && b.x0 <= a.x1 && a.y0 <= b.y1 && b.y0 <= a.y1 }

    /// What each frame's box is filled from, decided in a first decoding pass.
    final class FillPlan: @unchecked Sendable {
        /// The box can be filled from the last time its pixels were visible.
        var fromPast: [Bool] = []
        /// Pixels revealed after the pointer moved off, per box, and the first
        /// frame they are valid for (nothing changed from then until the reveal).
        var futurePatches: [Box: (pixels: [UInt8], validFrom: Int)] = [:]
    }

    private static func planFills(asset: AVAsset, track: AVAssetTrack, boxes: [Box?], times: [Double], width: Int, height: Int,
                                  pad: Int, cancellation: MediaExportCancellation,
                                  progress: (Double) -> Void) throws -> FillPlan {
        let plan = FillPlan()
        plan.fromPast = Array(repeating: true, count: boxes.count)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw PointerAnalysisError.readFailed(reader.error?.localizedDescription ?? "unknown") }
        defer { if reader.status == .reading { reader.cancelReading() } }
        let blocks = BlockHistory(width: width, height: height, pad: pad)
        /// Boxes waiting to be revealed, with the earliest frame that needs them.
        var pending: [Box: Int] = [:]
        var lastProgress = 0.0
        while let sample = output.copyNextSampleBuffer() {
            try cancellation.check()
            guard let buffer = CMSampleBufferGetImageBuffer(sample),
                  let f = nearestIndex(times, CMSampleBufferGetPresentationTimeStamp(sample).seconds) else { continue }
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { continue }
            let rb = CVPixelBufferGetBytesPerRow(buffer)
            let box = boxes[f]
            blocks.record(src: base, rowBytes: rb, frame: f, exclude: [box, f > 0 ? boxes[f - 1] : nil].compactMap { $0 })

            // Reveals: pending boxes the pointer no longer covers.
            for (pendingBox, since) in pending where box.map({ !intersects($0, pendingBox) }) ?? true {
                var pixels = [UInt8](repeating: 0, count: (pendingBox.x1 - pendingBox.x0 + 1) * (pendingBox.y1 - pendingBox.y0 + 1) * 4)
                let rowLength = (pendingBox.x1 - pendingBox.x0 + 1) * 4
                pixels.withUnsafeMutableBytes { dst in
                    for y in pendingBox.y0...pendingBox.y1 {
                        memcpy(dst.baseAddress! + (y - pendingBox.y0) * rowLength, base + y * rb + pendingBox.x0 * 4, rowLength)
                    }
                }
                // Valid for frames after the last change around the box.
                let lastChange = blocks.latestChange(around: pendingBox)
                plan.futurePatches[pendingBox] = (pixels, max(since, Int(lastChange)))
                pending[pendingBox] = nil
            }

            if let box {
                if !blocks.canFillFromPast(box) {
                    plan.fromPast[f] = false
                    if pending[box] == nil, plan.futurePatches[box] == nil { pending[box] = f }
                }
            }
            blocks.stamp(uncoveredBy: box, frame: f)
            let fraction = times.last.map { $0 > 0 ? times[f] / $0 : 0 } ?? 0
            if fraction - lastProgress > 0.01 { progress(fraction); lastProgress = fraction }
        }
        if reader.status == .failed { throw PointerAnalysisError.readFailed(reader.error?.localizedDescription ?? "unknown") }
        return plan
    }

    private static func nearestIndex(_ times: [Double], _ t: Double) -> Int? {
        guard !times.isEmpty else { return nil }
        var lo = 0, hi = times.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if times[mid] < t { lo = mid + 1 } else { hi = mid }
        }
        if lo > 0, abs(times[lo - 1] - t) < abs(times[lo] - t) { lo -= 1 }
        return abs(times[lo] - t) < 0.02 ? lo : nil
    }

    private static func colorProperties(_ format: CMFormatDescription?) -> [String: Any]? {
        guard let format,
              let primaries = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String,
              let transfer = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String,
              let matrix = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_YCbCrMatrix) as? String
        else { return [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                       AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                       AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2] }
        return [AVVideoColorPrimariesKey: primaries, AVVideoTransferFunctionKey: transfer, AVVideoYCbCrMatrixKey: matrix]
    }
}

nonisolated private final class FailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Error?
    var error: Error? { lock.lock(); defer { lock.unlock() }; return stored }
    func set(_ e: Error) { lock.lock(); if stored == nil { stored = e }; lock.unlock() }
}

/// Per 8×8 block: when it was last fully uncovered, and when the screen there
/// last changed (ignoring the pointer's own boxes).
nonisolated final class BlockHistory: @unchecked Sendable {
    typealias Box = PointerEraser.Box
    static let block = 8
    static let samples = [(2, 2), (6, 2), (2, 6), (6, 6), (4, 4)]

    let width: Int, height: Int, cols: Int, rows: Int, pad: Int
    private(set) var stamp: [Int32]
    private(set) var changed: [Int32]
    private var previous: [UInt8]
    private var hasPrevious = false

    init(width: Int, height: Int, pad: Int) {
        self.width = width
        self.height = height
        self.pad = pad
        cols = (width + Self.block - 1) / Self.block
        rows = (height + Self.block - 1) / Self.block
        stamp = Array(repeating: -1, count: cols * rows)
        changed = Array(repeating: -1, count: cols * rows)
        previous = Array(repeating: 0, count: cols * rows * Self.samples.count)
    }

    func record(src: UnsafePointer<UInt8>, rowBytes: Int, frame: Int, exclude: [Box]) {
        let padded = exclude.map { Box(x0: $0.x0 - pad, y0: $0.y0 - pad, x1: $0.x1 + pad, y1: $0.y1 + pad) }
        let n = Self.samples.count
        for r in 0..<rows {
            let rowY0 = r * Self.block, rowY1 = rowY0 + Self.block - 1
            let rowBoxes = padded.filter { $0.y0 <= rowY1 && $0.y1 >= rowY0 }
            for c in 0..<cols {
                let i = r * cols + c
                var moved = false
                for (k, o) in Self.samples.enumerated() {
                    let x = min(width - 1, c * Self.block + o.0), y = min(height - 1, r * Self.block + o.1)
                    let p = src + y * rowBytes + x * 4
                    let v = UInt8((UInt16(p[0]) + 2 * UInt16(p[1]) + UInt16(p[2])) / 4)
                    if hasPrevious, abs(Int(v) - Int(previous[i * n + k])) > 14,
                       !rowBoxes.contains(where: { x >= $0.x0 && x <= $0.x1 && y >= $0.y0 && y <= $0.y1 }) {
                        moved = true
                    }
                    previous[i * n + k] = v
                }
                if moved { changed[i] = Int32(frame) }
            }
        }
        hasPrevious = true
    }

    /// Marks every block the pointer box doesn't touch as seen at `frame`.
    func stamp(uncoveredBy box: Box?, frame: Int) {
        for r in 0..<rows {
            for c in 0..<cols {
                if let b = box {
                    let x0 = c * Self.block, y0 = r * Self.block
                    if PointerEraser.intersects(Box(x0: x0, y0: y0, x1: x0 + Self.block - 1, y1: y0 + Self.block - 1), b) { continue }
                }
                stamp[r * cols + c] = Int32(frame)
            }
        }
    }

    /// The pixels under `box` were last seen after anything around them changed.
    func canFillFromPast(_ box: Box) -> Bool {
        var oldest = Int32.max
        forBlocks(in: box) { oldest = min(oldest, stamp[$0]) }
        return oldest >= 0 && latestChange(around: box) <= oldest
    }

    func latestChange(around box: Box) -> Int32 {
        var latest: Int32 = -1
        let ring = Box(x0: max(0, box.x0 - Self.block), y0: max(0, box.y0 - Self.block),
                       x1: min(width - 1, box.x1 + Self.block), y1: min(height - 1, box.y1 + Self.block))
        forBlocks(in: ring) { latest = max(latest, changed[$0]) }
        return latest
    }

    func forBlocks(in box: Box, _ body: (Int) -> Void) {
        let c0 = max(0, box.x0 / Self.block), c1 = min(cols - 1, box.x1 / Self.block)
        let r0 = max(0, box.y0 / Self.block), r1 = min(rows - 1, box.y1 / Self.block)
        guard c0 <= c1, r0 <= r1 else { return }
        for r in r0...r1 { for c in c0...c1 { body(r * cols + c) } }
    }
}

/// Writing pass: keeps the last uncovered value of every pixel and fills
/// each box as the plan says.
nonisolated private final class EraseState: @unchecked Sendable {
    typealias Box = PointerEraser.Box

    let width: Int, height: Int
    let background: UnsafeMutablePointer<UInt8>
    /// The previous frame as written (pointer already removed).
    let previousOutput: UnsafeMutablePointer<UInt8>
    private var hasPreviousOutput = false
    let debug = ProcessInfo.processInfo.environment["STUDIO_DEBUG"] != nil

    init(width: Int, height: Int, pad: Int) {
        self.width = width
        self.height = height
        background = .allocate(capacity: width * height * 4)
        background.initialize(repeating: 0, count: width * height * 4)
        previousOutput = .allocate(capacity: width * height * 4)
        previousOutput.initialize(repeating: 0, count: width * height * 4)
    }

    deinit {
        background.deallocate()
        previousOutput.deallocate()
    }

    func process(source: CVPixelBuffer, destination: CVPixelBuffer, frame: Int?, box: Box?, previousBox: Box?,
                 plan: PointerEraser.FillPlan) {
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        guard let src = CVPixelBufferGetBaseAddress(source)?.assumingMemoryBound(to: UInt8.self),
              let dst = CVPixelBufferGetBaseAddress(destination)?.assumingMemoryBound(to: UInt8.self) else { return }
        let srb = CVPixelBufferGetBytesPerRow(source), drb = CVPixelBufferGetBytesPerRow(destination)
        let w = min(width, CVPixelBufferGetWidth(source)), h = min(height, CVPixelBufferGetHeight(source))
        for y in 0..<h { memcpy(dst + y * drb, src + y * srb, w * 4) }
        guard let f = frame else { return }

        if let box {
            let rowLength = (box.x1 - box.x0 + 1) * 4
            if plan.fromPast[f] {
                for y in box.y0...box.y1 {
                    memcpy(dst + y * drb + box.x0 * 4, background + (y * width + box.x0) * 4, rowLength)
                }
                if debug { print("frame \(f) past") }
            } else if let patch = plan.futurePatches[box], f >= patch.validFrom {
                patch.pixels.withUnsafeBytes { p in
                    for y in box.y0...box.y1 {
                        memcpy(dst + y * drb + box.x0 * 4, p.baseAddress! + (y - box.y0) * rowLength, rowLength)
                    }
                }
                if debug { print("frame \(f) future") }
            } else if hasPreviousOutput, let shift = scrollShift(src: src, rowBytes: srb, box: box) {
                // Content moving under a parked pointer: carry the previous
                // clean frame along with it.
                for y in box.y0...box.y1 {
                    for x in box.x0...box.x1 {
                        let sx = min(width - 1, max(0, x - shift.dx)), sy = min(height - 1, max(0, y - shift.dy))
                        memcpy(dst + y * drb + x * 4, previousOutput + (sy * width + sx) * 4, 4)
                    }
                }
                if debug { print("frame \(f) shift \(shift)") }
            } else {
                blend(dst: dst, rowBytes: drb, box: box)
                if debug { print("frame \(f) blend") }
            }
        }
        for y in 0..<h { memcpy(previousOutput + y * width * 4, dst + y * drb, w * 4) }
        hasPreviousOutput = true

        // Remember everything the pointer doesn't cover.
        for y in 0..<h {
            let row = background + y * width * 4, s = src + y * srb
            if let b = box, y >= b.y0, y <= b.y1 {
                if b.x0 > 0 { memcpy(row, s, b.x0 * 4) }
                if b.x1 + 1 < w { memcpy(row + (b.x1 + 1) * 4, s + (b.x1 + 1) * 4, (w - b.x1 - 1) * 4) }
            } else {
                memcpy(row, s, w * 4)
            }
        }
    }

    /// The translation (scrolling) that best maps the previous clean frame
    /// onto this one in a ring around the box, if it fits well.
    private func scrollShift(src: UnsafePointer<UInt8>, rowBytes: Int, box: Box) -> (dx: Int, dy: Int)? {
        let m = 48
        let ring = Box(x0: max(0, box.x0 - m), y0: max(0, box.y0 - m), x1: min(width - 1, box.x1 + m), y1: min(height - 1, box.y1 + m))
        // Sample the ring (outside the box) on a 3 px grid, by luma.
        var points: [(x: Int, y: Int, v: Int32)] = []
        for y in stride(from: ring.y0, through: ring.y1, by: 3) {
            for x in stride(from: ring.x0, through: ring.x1, by: 3) where !(x >= box.x0 && x <= box.x1 && y >= box.y0 && y <= box.y1) {
                let p = src + y * rowBytes + x * 4
                points.append((x, y, Int32(p[0]) + 2 * Int32(p[1]) + Int32(p[2])))
            }
        }
        guard points.count > 50 else { return nil }
        func cost(_ dx: Int, _ dy: Int, limit: Int64) -> Int64 {
            var total: Int64 = 0
            for p in points {
                let sx = p.x - dx, sy = p.y - dy
                guard sx >= 0, sy >= 0, sx < width, sy < height else { total += 400; continue }
                let q = previousOutput + (sy * width + sx) * 4
                total += Int64(abs(p.v - (Int32(q[0]) + 2 * Int32(q[1]) + Int32(q[2]))))
                if total > limit { return total }
            }
            return total
        }
        var best = (dx: 0, dy: 0, cost: cost(0, 0, limit: .max))
        let reach = 96
        for d in 1...reach {
            for (dx, dy) in [(0, d), (0, -d), (d, 0), (-d, 0)] {
                let c = cost(dx, dy, limit: best.cost)
                if c < best.cost { best = (dx, dy, c) }
            }
        }
        // Mean error per sample (luma ×4) must be small for the fit to count.
        let mean = Double(best.cost) / Double(points.count) / 4
        // No movement is no evidence: the change that made the box stale was elsewhere.
        return mean < 6 && (best.dx != 0 || best.dy != 0) ? (best.dx, best.dy) : nil
    }

    /// Last resort: the box takes the most common surrounding color (UI
    /// backgrounds are mostly flat), feathered into a Coons patch from the
    /// edge pixels so it joins its surroundings without streaking detail in.
    private func blend(dst: UnsafeMutablePointer<UInt8>, rowBytes: Int, box: Box) {
        let hasL = box.x0 > 0, hasR = box.x1 < width - 1, hasT = box.y0 > 0, hasB = box.y1 < height - 1
        let lx = hasL ? box.x0 - 1 : box.x1 + 1, rx = hasR ? box.x1 + 1 : box.x0 - 1
        let ty = hasT ? box.y0 - 1 : box.y1 + 1, by = hasB ? box.y1 + 1 : box.y0 - 1
        guard (hasL || hasR), (hasT || hasB) else { return }
        func px(_ x: Int, _ y: Int, _ ch: Int) -> Double { Double(dst[y * rowBytes + x * 4 + ch]) }

        // Median of the one-pixel ring around the box, per channel.
        var ring: [[UInt8]] = Array(repeating: [], count: 4)
        for x in box.x0...box.x1 { for y in [ty, by] { for ch in 0..<4 { ring[ch].append(dst[y * rowBytes + x * 4 + ch]) } } }
        for y in box.y0...box.y1 { for x in [lx, rx] { for ch in 0..<4 { ring[ch].append(dst[y * rowBytes + x * 4 + ch]) } } }
        let median = ring.map { values -> Double in Double(values.sorted()[values.count / 2]) }

        let bw = Double(box.x1 - box.x0 + 2), bh = Double(box.y1 - box.y0 + 2)
        let feather = 3.0
        for y in box.y0...box.y1 {
            let v = Double(y - box.y0 + 1) / bh
            for x in box.x0...box.x1 {
                let u = Double(x - box.x0 + 1) / bw
                let edge = Double(min(x - box.x0 + 1, box.x1 - x + 1, y - box.y0 + 1, box.y1 - y + 1))
                let w = min(1, edge / feather)
                for ch in 0..<4 {
                    let L = px(lx, y, ch), R = px(rx, y, ch), T = px(x, ty, ch), B = px(x, by, ch)
                    let TL = px(lx, ty, ch), TR = px(rx, ty, ch), BL = px(lx, by, ch), BR = px(rx, by, ch)
                    let coons = (1 - u) * L + u * R + (1 - v) * T + v * B
                        - ((1 - u) * (1 - v) * TL + u * (1 - v) * TR + (1 - u) * v * BL + u * v * BR)
                    let value = (1 - w) * coons + w * median[ch]
                    dst[y * rowBytes + x * 4 + ch] = UInt8(max(0, min(255, value.rounded())))
                }
            }
        }
    }
}
