import AppKit

/// The system cursors Studio looks for in a video.
nonisolated enum PointerKind: UInt8, CaseIterable, Sendable {
    case arrow, pointingHand, iBeam, openHand, closedHand, crosshair, resizeLeftRight, resizeUpDown, notAllowed

    /// Shapes tried when the pointer has to be found anywhere in a frame.
    /// The rest (notably the I-beam, which resembles text) are only tried
    /// near the last known position.
    static let acquisition: [PointerKind] = [.arrow, .pointingHand]

    @MainActor var cursor: NSCursor {
        switch self {
        case .arrow: return .arrow
        case .pointingHand: return .pointingHand
        case .iBeam: return .iBeam
        case .openHand: return .openHand
        case .closedHand: return .closedHand
        case .crosshair: return .crosshair
        case .resizeLeftRight: return .resizeLeftRight
        case .resizeUpDown: return .resizeUpDown
        case .notAllowed: return .operationNotAllowed
        }
    }
}

/// A cursor rasterized at one scale (video pixels per cursor point): the
/// opaque pixels as luma samples, ordered so a wrong position is rejected
/// after a handful of them.
nonisolated struct PointerTemplate: Sendable {
    struct Sample: Sendable { var dx: Int32; var dy: Int32; var luma: Int32 }

    let kind: PointerKind
    let scale: CGFloat
    /// Raster size in video pixels.
    let width: Int
    let height: Int
    /// Hotspot in video pixels from the raster's top-left corner.
    let hotspotX: Int
    let hotspotY: Int
    let samples: [Sample]
}

/// Cursor artwork for the editor, which draws its own pointer from these.
nonisolated struct PointerArtwork: Sendable {
    let kind: PointerKind
    /// Hotspot and size in points, PNG at 4×.
    let hotspot: CGPoint
    let size: CGSize
    let png: Data
}

@MainActor
enum PointerTemplates {
    /// Rasterizes every cursor kind at `scale`.
    /// Rasterizes every cursor kind at `scale`, in four half-pixel phases:
    /// pointers move in sub-pixel steps and videos are often rescaled.
    static func make(scale: CGFloat, kinds: [PointerKind] = PointerKind.allCases) -> [PointerTemplate] {
        let phases: [CGFloat] = [0, 0.5]
        return kinds.flatMap { kind in
            phases.flatMap { px in phases.compactMap { py in template(kind, scale: scale, phase: CGPoint(x: px, y: py)) } }
        }
    }

    static func artwork() -> [PointerArtwork] {
        PointerKind.allCases.compactMap { kind in
            let cursor = kind.cursor
            guard let raster = rasterize(cursor.image, pixelScale: 4),
                  let png = NSBitmapImageRep(cgImage: raster).representation(using: .png, properties: [:]) else { return nil }
            return PointerArtwork(kind: kind, hotspot: cursor.hotSpot, size: cursor.image.size, png: png)
        }
    }

    /// A fully transparent shape, shown while the pointer is hidden in the video.
    static func transparentPNG() -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }

    /// The cursor drawn so its hotspot lands on a pixel center plus `phase`.
    private static func template(_ kind: PointerKind, scale: CGFloat, phase: CGPoint) -> PointerTemplate? {
        let cursor = kind.cursor
        let size = cursor.image.size
        let hx = cursor.hotSpot.x * scale, hy = cursor.hotSpot.y * scale
        // Shift so the hotspot sits at an integer pixel (after the phase).
        let shiftX = hx.rounded(.up) - hx + phase.x, shiftY = hy.rounded(.up) - hy + phase.y
        let width = Int((size.width * scale + shiftX).rounded(.up)), height = Int((size.height * scale + shiftY).rounded(.up))
        guard width > 2, height > 2 else { return nil }
        let frame = CGRect(x: shiftX, y: CGFloat(height) - shiftY - size.height * scale,
                           width: size.width * scale, height: size.height * scale)
        guard let raster = rasterize(cursor.image, width: width, height: height, in: frame),
              let data = raster.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return nil }
        let rowBytes = raster.bytesPerRow
        func collect(minAlpha: UInt8) -> [PointerTemplate.Sample] {
            var samples: [PointerTemplate.Sample] = []
            for y in 0..<height {
                for x in 0..<width {
                    let p = bytes + y * rowBytes + x * 4
                    guard p[3] >= minAlpha else { continue }
                    let a = Double(p[3]) / 255  // un-premultiply
                    let luma = (0.2126 * Double(p[0]) + 0.7152 * Double(p[1]) + 0.0722 * Double(p[2])) / a
                    samples.append(.init(dx: Int32(x), dy: Int32(y), luma: Int32(min(255, luma.rounded()))))
                }
            }
            return samples
        }
        // A template must hold both the dark body and the light outline (or
        // vice versa); a one-tone template matches any flat dark area. Prefer
        // fully opaque pixels, whose values don't depend on the background.
        func balanced(_ s: [PointerTemplate.Sample]) -> Bool {
            let dark = s.filter { $0.luma < 90 }.count, light = s.filter { $0.luma > 170 }.count
            return s.count >= 24 && dark * 6 >= s.count && light * 6 >= s.count
        }
        var samples = collect(minAlpha: 235)
        if !balanced(samples) { samples = collect(minAlpha: 200) }
        guard balanced(samples) else { return nil }
        // Deterministic shuffle so early samples spread across the shape and
        // mix dark fill with light outline.
        var rng = SplitMix(seed: UInt64(kind.rawValue) &+ 0x9E37)
        for i in stride(from: samples.count - 1, to: 0, by: -1) {
            samples.swapAt(i, Int(rng.next() % UInt64(i + 1)))
        }
        let dark = samples.filter { $0.luma < 110 }, light = samples.filter { $0.luma >= 110 }
        var ordered: [PointerTemplate.Sample] = []
        var di = 0, li = 0
        while ordered.count < 32, di < dark.count || li < light.count {
            if di < dark.count { ordered.append(dark[di]); di += 1 }
            if li < light.count { ordered.append(light[li]); li += 1 }
        }
        ordered += dark[di...] + light[li...]
        return PointerTemplate(kind: kind, scale: scale, width: width, height: height,
                               hotspotX: Int((hx + shiftX).rounded()), hotspotY: Int((hy + shiftY).rounded()),
                               samples: ordered)
    }

    private static func rasterize(_ image: NSImage, pixelScale: CGFloat) -> CGImage? {
        rasterize(image, width: Int((image.size.width * pixelScale).rounded()),
                  height: Int((image.size.height * pixelScale).rounded()))
    }

    /// Cursor images can be vector, so draw them rather than reading bitmap reps.
    /// RGBA, straight-ish (premultiplied, but only opaque pixels are used).
    private static func rasterize(_ image: NSImage, width: Int, height: Int, in rect: CGRect? = nil) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        image.draw(in: rect ?? NSRect(x: 0, y: 0, width: width, height: height), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }
}

nonisolated struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
