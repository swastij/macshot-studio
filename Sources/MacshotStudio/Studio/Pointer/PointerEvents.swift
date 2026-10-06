import CoreGraphics
import Foundation

/// Turns a tracked pointer into macshot telemetry: positions, shapes, and
/// clicks and typing inferred from how the screen reacts.
nonisolated enum PointerEvents {
    struct Click: Codable, Sendable { var time: Double; var x: Float; var y: Float }

    struct Inferred: Codable, Sendable {
        var clicks: [Click] = []
        /// Times of inferred key presses (the pointer hides while typing).
        var typing: [Double] = []
    }

    static let hiddenShapeID: UInt32 = 100
    static func shapeID(_ kind: UInt8) -> UInt32 { UInt32(kind) + 1 }

    // MARK: Inference

    /// A click is a pointer that travels, stops, and the screen answers
    /// (near the pointer, or broadly) while it is still parked.
    static func infer(_ track: PointerTrack) -> Inferred {
        let frames = track.frames
        let s = Float(track.scale)
        var result = Inferred()
        guard frames.count > 2 else { return result }

        func distance(_ a: PointerFrame, _ b: PointerFrame) -> Float {
            let dx = (a.x - b.x) / s, dy = (a.y - b.y) / s
            return (dx * dx + dy * dy).squareRoot()
        }

        var i = 1
        var armed = true
        var anchor = frames[0]
        while i < frames.count {
            let f = frames[i]
            if !armed, f.visible, distance(f, anchor) > 6 { armed = true }
            guard armed, f.visible else { i += 1; continue }

            // Did the pointer travel in the last half second and stop here?
            var travelled: Float = 0
            var k = i - 1
            while k >= 0, f.time - frames[k].time <= 0.6 {
                if frames[k].visible { travelled = max(travelled, distance(frames[k], f)) }
                k -= 1
            }
            let next = i + 1 < frames.count ? frames[i + 1] : f
            let stopped = next.visible && distance(next, f) < 1.5
            guard travelled >= 10, stopped else { i += 1; continue }

            // Baseline activity just before the stop (animations, video).
            var before: [Float] = []
            var b = i - 1
            while b >= 0, f.time - frames[b].time <= 0.5 { before.append(frames[b].globalChange); b -= 1 }
            before.sort()
            let baseline = before.isEmpty ? 0 : before[before.count / 2]

            var j = i
            var response: Int?
            while j < frames.count, frames[j].time - f.time <= 1.0 {
                let g = frames[j]
                if g.visible && distance(g, f) > 3 { break }
                if g.localChange >= 0.012 || g.globalChange >= max(0.003, baseline * 3 + 0.001) {
                    response = j
                    break
                }
                j += 1
            }
            if let r = response {
                let time = max(f.time, frames[r].time - 0.08)
                result.clicks.append(Click(time: time, x: f.x, y: f.y))
                armed = false
                anchor = f
                i = r + 1
            } else {
                i += 1
            }
        }

        // Typing: the pointer vanishes while the screen keeps changing near
        // where it was (macOS hides the pointer as you type).
        // A typed character changes only a few 8 px cells of the ~1250·s²
        // cells within 160 pt of the pointer, so the bar is two cells.
        let twoCells = Float(2 / (1256 * track.scale * track.scale))
        var lastKey = -Double.infinity
        for f in frames {
            guard !f.visible, f.localChange >= twoCells, f.time - lastKey >= 0.12 else { continue }
            result.typing.append(f.time)
            lastKey = f.time
        }
        return result
    }

    // MARK: Telemetry

    static func telemetry(for track: PointerTrack, inferred: Inferred, artwork: [PointerArtwork],
                          hiddenPNG: Data, pointerRemovedFromVideo: Bool) throws -> Data {
        let bounds = CGRect(x: 0, y: 0, width: track.width, height: track.height).applying(track.transform)
        let upright = CGSize(width: abs(bounds.width), height: abs(bounds.height))
        func normalized(_ x: Float, _ y: Float) -> (Float, Float) {
            let p = CGPoint(x: CGFloat(x), y: CGFloat(y)).applying(track.transform)
            return (Float((p.x - bounds.minX) / upright.width), Float((p.y - bounds.minY) / upright.height))
        }

        let header = CursorTelemetry.Header(
            sourcePointSize: CGSize(width: upright.width / track.scale, height: upright.height / track.scale),
            pixelSize: upright, frameRate: Int(track.frameRate.rounded()),
            cursorHiddenInVideo: pointerRemovedFromVideo, overlaysInTelemetry: false)
        var data = try CursorTelemetry.encodeHeader(header)

        var events: [CursorTelemetry.Event] = [.start(time: 0)]
        for art in artwork {
            events.append(.shapeDefinition(.init(id: shapeID(art.kind.rawValue), hotspot: art.hotspot, size: art.size, png: art.png)))
        }
        events.append(.shapeDefinition(.init(id: hiddenShapeID, hotspot: .zero, size: CGSize(width: 1, height: 1), png: hiddenPNG)))

        // Merge frames, clicks and keys in time order.
        var clicks = inferred.clicks[...]
        var keys = inferred.typing[...]
        var shape: UInt32?
        func flushEvents(until t: Double) {
            while let c = clicks.first, c.time <= t {
                let (x, y) = normalized(c.x, c.y)
                events.append(.button(time: c.time, button: .left, down: true, x: x, y: y))
                events.append(.button(time: c.time + 0.08, button: .left, down: false, x: x, y: y))
                clicks = clicks.dropFirst()
            }
            while let k = keys.first, k <= t {
                events.append(.key(time: k, down: true, keyCode: 0, modifiers: 0, characters: ""))
                events.append(.key(time: k + 0.05, down: false, keyCode: 0, modifiers: 0, characters: ""))
                keys = keys.dropFirst()
            }
        }
        var lastPosition: (Float, Float)?
        for f in track.frames {
            flushEvents(until: f.time)
            let id = f.visible ? shapeID(f.kind) : hiddenShapeID
            if id != shape { events.append(.shape(time: f.time, id: id)); shape = id }
            let p = normalized(f.x, f.y)
            if lastPosition.map({ $0 != p }) ?? true {
                events.append(.move(time: f.time, x: p.0, y: p.1))
                lastPosition = p
            }
        }
        flushEvents(until: .infinity)
        // Button events re-sample the position; keep time order for the reader.
        for event in events { CursorTelemetry.encode(event, into: &data) }
        return data
    }
}
