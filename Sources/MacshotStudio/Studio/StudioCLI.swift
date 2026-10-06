import AppKit
import AVFoundation

/// Headless pointer analysis for testing and scripting:
///
///   macshot-studio --analyze <video> [--mode track|replace] [--dump frames.json]
///
/// Prints a summary and writes the same files the app would.
@MainActor
enum StudioCLI {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render"), i + 2 < args.count {
            let style = args.firstIndex(of: "--style").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
            Task { @MainActor in
                do {
                    try await render(URL(fileURLWithPath: args[i + 1]), to: URL(fileURLWithPath: args[i + 2]), style: style)
                    exit(0)
                } catch {
                    print("error: \(error)")
                    exit(1)
                }
            }
            RunLoop.main.run()
            return true
        }
        if let i = args.firstIndex(of: "--probe"), i + 5 < args.count {
            probe(url: URL(fileURLWithPath: args[i + 1]), time: Double(args[i + 2])!, x: Int(args[i + 3])!,
                  y: Int(args[i + 4])!, scale: CGFloat(Double(args[i + 5])!))
            exit(0)
        }
        guard let i = args.firstIndex(of: "--analyze"), i + 1 < args.count else { return false }
        let url = URL(fileURLWithPath: args[i + 1])
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        let mode = PointerMode(rawValue: value("--mode") ?? "replace") ?? .replace
        let dump = value("--dump").map { URL(fileURLWithPath: $0) }

        let started = Date()
        PointerAnalysis.run(url: url, mode: mode, force: true, cancellation: MediaExportCancellation(),
                            progress: { _ in }, dump: dump) { result in
            let elapsed = Date().timeIntervalSince(started)
            switch result {
            case .success(let outcome):
                print(outcome.summary)
                print(String(format: "elapsed %.1fs", elapsed))
                print("open: \(outcome.openURL.path)")
                exit(0)
            case .failure(let error):
                print("error: \(error.localizedDescription)")
                exit(1)
            }
        }
        RunLoop.main.run()
        return true
    }

    /// Debug: template scores around a known hotspot, and the best match anywhere.
    private static func probe(url: URL, time: Double, x: Int, y: Int, scale: CGFloat) {
        let asset = AVURLAsset(url: url)
        let track = asset.tracks(withMediaType: .video)[0]
        guard let luma = try? PointerTracker.readLuma(asset: asset, track: track, at: time) else { print("no frame"); return }
        let templates = PointerTemplates.make(scale: scale)
        let matcher = PointerMatcher(templates: templates, rowBytes: luma.width)
        luma.withFrame { frame in
            for (i, t) in templates.enumerated() {
                var best = (Int32.max, 0, 0)
                for dy in -4...4 { for dx in -4...4 {
                    let s = matcher.score(frame, template: i, hx: x + dx, hy: y + dy, limit: 255)
                    if s < best.0 { best = (s, dx, dy) }
                } }
                print("\(t.kind) \(t.width)x\(t.height) hs(\(t.hotspotX),\(t.hotspotY)) n=\(t.samples.count) best mean=\(Double(best.0) / 16) at d(\(best.1),\(best.2))")
            }
            if let m = matcher.searchAll(frame, candidates: Array(templates.indices)) {
                print("global best: \(templates[m.templateIndex].kind) at (\(m.x), \(m.y)) mean=\(Double(m.score) / 16)")
            } else { print("global: none under threshold") }
            // Print the luma patch around the hotspot.
            for yy in stride(from: y - 4, to: y + 40, by: 3) {
                var line = ""
                for xx in stride(from: x - 4, to: x + 30, by: 2) {
                    let v = frame.base[max(0, yy) * frame.rowBytes + max(0, xx)]
                    line += v < 60 ? "#" : v < 160 ? "+" : "."
                }
                print(line)
            }
        }
        let t = templates[0]
        print("arrow template:")
        var grid = Array(repeating: Array(repeating: " ", count: t.width), count: t.height)
        for s in t.samples { grid[Int(s.dy)][Int(s.dx)] = s.luma < 60 ? "#" : s.luma < 160 ? "+" : "." }
        for row in grid { print(row.joined()) }
    }

    /// End-to-end check through macshot's own editor model: what pointer data
    /// it sees, Auto Zoom, a restyled pointer, and an MP4 export.
    private static func render(_ url: URL, to output: URL, style: String?) async throws {
        let snapshot = try VideoSourceSnapshot.prepare(url: url, deleteOnClose: false)
        let prepared = try await PreparedVideoSource.load(snapshot)
        guard let asset = prepared.asset else { print("not a video"); return }
        let document = VideoEditorDocument(prepared: prepared, asset: asset)
        let recording = document.recording
        print("pointer data: \(document.hasPointerData), restyleable: \(document.cursorIsEditable), "
              + "samples \(recording?.times.count ?? 0), clicks \(recording?.clicks.count ?? 0), keys \(recording?.keys.count ?? 0), "
              + "shapes \(recording?.shapes.count ?? 0), px/pt \(recording?.pixelsPerPoint ?? 0)")
        guard let recording else { return }
        let p = document.project
        let track = document.cursorTrack(onReady: {})
        let suggestions = AutoZoomPlanner.suggestions(recording: recording, track: track, range: p.trimStart...p.trimEnd,
                                                      level: CGFloat(p.look.zoom.defaultLevel))
        print("auto zoom: " + suggestions.map { String(format: "%.2f-%.2fs %.1fx at (%.2f, %.2f)", $0.start, $0.end, $0.level, $0.center.x, $0.center.y) }
            .joined(separator: ", "))
        document.edit([.segments, .render]) { project in
            project.zooms.removeAll()
            for s in suggestions {
                project.zooms.append(VideoZoomSegment(startTime: s.start, endTime: s.end, zoomLevel: s.level, center: s.center,
                                                      fadeIn: 0.6, fadeOut: 0.5, followsCursor: true, isAutomatic: true))
            }
            if let style, let appearance = VideoCursorStyle.Appearance(rawValue: style) {
                project.look.cursor.appearance = appearance
                project.look.cursor.size = 1.6
                project.look.cursor.clickEffect = .ripple
            }
        }
        try? FileManager.default.removeItem(at: output)
        var settings = VideoExportSettings()
        settings.quality = .high
        let job = try VideoEditorExporter(document: document).mp4Job(settings, outputURL: output)
        try await job.export(to: output)
        print("exported \(output.path)")
    }
}
