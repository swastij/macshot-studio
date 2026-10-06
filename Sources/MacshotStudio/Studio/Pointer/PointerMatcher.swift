import Foundation

/// An 8-bit luma plane (row 0 at the top).
nonisolated struct LumaFrame: @unchecked Sendable {
    let base: UnsafePointer<UInt8>
    let rowBytes: Int
    let width: Int
    let height: Int
}

/// A rectangle of hotspot positions to skip (inclusive).
nonisolated struct Zone: Sendable, Equatable {
    var x0: Int, y0: Int, x1: Int, y1: Int
    init(x0: Int, y0: Int, x1: Int, y1: Int) { self.x0 = x0; self.y0 = y0; self.x1 = x1; self.y1 = y1 }
    init(around x: Int, _ y: Int, radius r: Int) { self.init(x0: x - r, y0: y - r, x1: x + r, y1: y + r) }
    func contains(_ x: Int, _ y: Int) -> Bool { x >= x0 && x <= x1 && y >= y0 && y <= y1 }
}

nonisolated struct PointerMatch: Sendable {
    var templateIndex: Int
    /// Hotspot in frame pixels.
    var x: Int
    var y: Int
    /// Mean absolute luma difference × 16 (lower is better).
    var score: Int32
}

/// Templates bound to one frame layout: sample offsets are precomputed for
/// the plane's row stride so the inner loop is a load, subtract and add.
nonisolated final class PointerMatcher: @unchecked Sendable {
    /// Mean luma difference (0…255) a match must stay under.
    static let threshold: Int32 = 30
    /// Per-sample cap so a few occluded pixels can't sink a match, while a
    /// black-for-white mismatch (a smaller cursor fitted inside a larger
    /// one) still counts in full.
    private static let clip: Int32 = 160

    let templates: [PointerTemplate]
    let rowBytes: Int
    private let offsets: [UnsafeMutablePointer<Int>]
    private let lumas: [UnsafeMutablePointer<Int32>]

    init(templates: [PointerTemplate], rowBytes: Int) {
        self.templates = templates
        self.rowBytes = rowBytes
        looseness = templates.map { $0.kind == .iBeam ? 18 : 16 }
        thin = templates.map { $0.kind == .iBeam || $0.kind == .crosshair }
        // Rarer shapes must fit clearly better before they are believed.
        penalty = templates.map {
            switch $0.kind {
            case .arrow, .pointingHand: return 0
            case .iBeam, .openHand, .closedHand: return 3 * 16
            default: return 6 * 16
            }
        }
        offsets = templates.map { t in
            let p = UnsafeMutablePointer<Int>.allocate(capacity: t.samples.count)
            for (i, s) in t.samples.enumerated() { p[i] = Int(s.dy) * rowBytes + Int(s.dx) }
            return p
        }
        lumas = templates.map { t in
            let p = UnsafeMutablePointer<Int32>.allocate(capacity: t.samples.count)
            for (i, s) in t.samples.enumerated() { p[i] = s.luma }
            return p
        }
    }

    deinit {
        offsets.forEach { $0.deallocate() }
        lumas.forEach { $0.deallocate() }
    }

    /// Score with the hotspot at (hx, hy); `Int32.max` when rejected.
    /// Thin shapes (I-beam, crosshair) lose more to compression and scaling.
    private let looseness: [Int32]
    /// Added to a shape's score (×16) when ranking and accepting matches.
    let penalty: [Int32]
    /// Thin shapes fall apart a pixel off, so the coarse grid can't skip them.
    private let thin: [Bool]

    @inline(__always)
    func limit(_ base: Int32, template i: Int) -> Int32 { base * looseness[i] / 16 }

    @inline(__always)
    func score(_ frame: LumaFrame, template i: Int, hx: Int, hy: Int, limit base: Int32 = PointerMatcher.threshold) -> Int32 {
        let t = templates[i]
        let limit = base * looseness[i] / 16
        let ox = hx - t.hotspotX, oy = hy - t.hotspotY
        guard ox >= 0, oy >= 0, ox + t.width <= frame.width, oy + t.height <= frame.height else {
            return clippedScore(frame, template: i, ox: ox, oy: oy, limit: limit)
        }
        let base = frame.base + oy * frame.rowBytes + ox
        let offs = offsets[i], ls = lumas[i]
        let n = t.samples.count
        let clip = Self.clip
        var sum: Int32 = 0
        var k = 0
        // Staged early exit: generous bounds (2.5×, 1.6×) on the first
        // samples, the real threshold on the full set.
        @inline(__always) func run(to end: Int) {
            while k < end {
                sum &+= min(abs(Int32(base[offs[k]]) - ls[k]), clip)
                k += 1
            }
        }
        let first = min(16, n), second = min(64, n)
        run(to: first)
        if sum * 16 > limit * Int32(first) * 40 { return .max }
        run(to: second)
        if sum * 16 > limit * Int32(second) * 26 { return .max }
        run(to: n)
        if sum > limit * Int32(n) { return .max }
        return sum * 16 / Int32(n)
    }

    /// Pointer partly outside the frame (menu bar, screen edges): score the
    /// visible samples if enough of the shape is in view.
    private func clippedScore(_ frame: LumaFrame, template i: Int, ox: Int, oy: Int, limit: Int32) -> Int32 {
        let t = templates[i]
        var sum: Int32 = 0, used: Int32 = 0
        for s in t.samples {
            let x = ox + Int(s.dx), y = oy + Int(s.dy)
            guard x >= 0, y >= 0, x < frame.width, y < frame.height else { continue }
            sum += min(abs(Int32(frame.base[y * frame.rowBytes + x]) - s.luma), Self.clip)
            used += 1
        }
        guard used * 10 >= Int32(t.samples.count) * 6 else { return .max }
        let mean16 = sum * 16 / used
        return mean16 <= limit * 16 ? mean16 : .max
    }

    /// Best match with the hotspot inside `rect` (inclusive bounds), trying
    /// `candidates` template indices at `step`, then refining at 1 px.
    func search(_ frame: LumaFrame, candidates: [Int], x0: Int, y0: Int, x1: Int, y1: Int, step: Int,
                limit: Int32 = PointerMatcher.threshold, excluding zones: [Zone] = []) -> PointerMatch? {
        let x0 = max(0, x0), y0 = max(0, y0)
        let x1 = min(frame.width - 1, x1), y1 = min(frame.height - 1, y1)
        guard x0 <= x1, y0 <= y1 else { return nil }
        var coarse: [PointerMatch] = []
        for i in candidates {
            let step = thin[i] ? 1 : step
            let bound = coarseLimit(limit, step: step)
            var best: PointerMatch?
            var y = y0
            while y <= y1 {
                var x = x0
                let rowZones = zones.filter { y >= $0.y0 && y <= $0.y1 }
                while x <= x1 {
                    if let z = rowZones.first(where: { x >= $0.x0 && x <= $0.x1 }) { x = z.x1 + 1; continue }
                    let s = score(frame, template: i, hx: x, hy: y, limit: bound)
                    if s < (best?.score ?? .max) { best = PointerMatch(templateIndex: i, x: x, y: y, score: s) }
                    x += step
                }
                y += step
            }
            if let best { coarse.append(best) }
        }
        return refine(frame, coarse, step: step, limit: limit)
    }

    /// A coarse grid lands up to a pixel off, so it uses a looser bound and
    /// the 1 px refinement must meet the real one.
    private func coarseLimit(_ limit: Int32, step: Int) -> Int32 { step > 1 ? limit * 8 / 5 : limit }

    /// Refines each template's coarse winner and returns the best accepted one.
    private func refine(_ frame: LumaFrame, _ coarse: [PointerMatch], step: Int, limit: Int32) -> PointerMatch? {
        var winner: PointerMatch?
        for c in coarse {
            var found = c
            let r = thin[c.templateIndex] ? 0 : step - 1
            if r > 0 {
                found.score = .max
                for y in (c.y - r)...(c.y + r) {
                    for x in (c.x - r)...(c.x + r) {
                        let s = score(frame, template: c.templateIndex, hx: x, hy: y, limit: limit)
                        if s < found.score { found = PointerMatch(templateIndex: c.templateIndex, x: x, y: y, score: s) }
                    }
                }
            }
            let ranked = found.score == .max ? Int32.max : found.score + penalty[found.templateIndex]
            guard ranked <= self.limit(limit, template: found.templateIndex) * 16 else { continue }
            if ranked < (winner.map { $0.score + penalty[$0.templateIndex] } ?? .max) { winner = found }
        }
        return winner
    }

    /// Whole-frame search, split into bands across cores.
    func searchAll(_ frame: LumaFrame, candidates: [Int], step: Int = 2,
                   limit: Int32 = PointerMatcher.threshold, excluding zones: [Zone] = []) -> PointerMatch? {
        let bands = max(1, min(16, ProcessInfo.processInfo.activeProcessorCount * 2))
        let bandHeight = (frame.height + bands - 1) / bands
        let results = UnsafeMutableBufferPointer<PointerMatch?>.allocate(capacity: bands)
        results.initialize(repeating: nil)
        defer { results.deallocate() }
        DispatchQueue.concurrentPerform(iterations: bands) { b in
            let y0 = b * bandHeight
            let y1 = min(frame.height - 1, y0 + bandHeight - 1)
            results[b] = search(frame, candidates: candidates, x0: 0, y0: y0, x1: frame.width - 1, y1: y1,
                                step: step, limit: limit, excluding: zones)
        }
        return results.compactMap { $0 }.min { $0.score + penalty[$0.templateIndex] < $1.score + penalty[$1.templateIndex] }
    }

    /// Best match with the hotspot in any of the masked grid cells: the
    /// places where the screen just changed.
    func search(_ frame: LumaFrame, candidates: [Int], cells mask: CellMask, step: Int = 2,
                limit: Int32 = PointerMatcher.threshold, excluding zones: [Zone] = []) -> PointerMatch? {
        let cells = mask.indices
        guard !cells.isEmpty else { return nil }
        let chunks = max(1, min(16, cells.count / 64))
        let per = (cells.count + chunks - 1) / chunks
        let n = templates.count
        // Best coarse match per template, per chunk.
        let results = UnsafeMutableBufferPointer<PointerMatch?>.allocate(capacity: chunks * n)
        results.initialize(repeating: nil)
        defer { results.deallocate() }
        DispatchQueue.concurrentPerform(iterations: chunks) { c in
            for i in candidates {
                let step = thin[i] ? 1 : step
                let bound = coarseLimit(limit, step: step)
                var best: PointerMatch?
                for k in (c * per)..<min(cells.count, (c + 1) * per) {
                    let x0 = (cells[k] % mask.cols) * mask.step, y0 = (cells[k] / mask.cols) * mask.step
                    var y = y0
                    while y < min(frame.height, y0 + mask.step) {
                        var x = x0
                        while x < min(frame.width, x0 + mask.step) {
                            if zones.isEmpty || !zones.contains(where: { $0.contains(x, y) }) {
                                let s = score(frame, template: i, hx: x, hy: y, limit: bound)
                                if s < (best?.score ?? .max) { best = PointerMatch(templateIndex: i, x: x, y: y, score: s) }
                            }
                            x += step
                        }
                        y += step
                    }
                }
                results[c * n + i] = best
            }
        }
        var coarse: [PointerMatch] = []
        for i in candidates {
            if let best = (0..<chunks).compactMap({ results[$0 * n + i] }).min(by: { $0.score < $1.score }) { coarse.append(best) }
        }
        return refine(frame, coarse, step: step, limit: limit)
    }
}

/// Grid cells (of `step` pixels) where something changed, grown by the
/// pointer's size so every hotspot that could explain the change is covered.
nonisolated struct CellMask: Sendable {
    let cols: Int
    let rows: Int
    let step: Int
    private(set) var indices: [Int] = []

    init(cols: Int, rows: Int, step: Int) { self.cols = cols; self.rows = rows; self.step = step }

    init(changed: [Bool], cols: Int, rows: Int, step: Int, grow: Int, within zone: Zone? = nil) {
        self.init(cols: cols, rows: rows, step: step)
        var marked = [Bool](repeating: false, count: cols * rows)
        for r in 0..<rows {
            for c in 0..<cols where changed[r * cols + c] {
                for rr in max(0, r - grow)...min(rows - 1, r + grow) {
                    for cc in max(0, c - grow)...min(cols - 1, c + grow) { marked[rr * cols + cc] = true }
                }
            }
        }
        for i in marked.indices where marked[i] {
            if let zone, !zone.contains((i % cols) * step, (i / cols) * step) { continue }
            indices.append(i)
        }
    }

    var fraction: Double { Double(indices.count) / Double(max(1, cols * rows)) }
}
