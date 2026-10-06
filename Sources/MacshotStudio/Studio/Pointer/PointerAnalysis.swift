import AppKit
import AVFoundation
import CryptoKit

nonisolated enum PointerMode: String, Codable, Sendable {
    /// Paint the recorded pointer out and let the editor draw a restyleable one.
    case replace
    /// Keep the recorded pointer; use its positions for zooms only.
    case track
}

nonisolated struct PointerOutcome: Sendable {
    /// The file to open in the editor: the cleaned copy or the original.
    var openURL: URL
    var summary: String
}

/// Runs pointer detection for a video and stores the results where the
/// editor picks them up. Results are cached per file (path, size, date).
@MainActor
enum PointerAnalysis {
    nonisolated private struct Record: Codable {
        var mode: PointerMode
        var summary: String
        var version: Int
    }

    /// Bump when detection changes enough that old results should be redone.
    nonisolated private static let version = 1

    /// The previously analysed file to open, if this video was done before.
    static func cachedOpenURL(for url: URL, mode: PointerMode) -> URL? {
        guard let folder = cacheFolder(for: url),
              let data = try? Data(contentsOf: folder.appendingPathComponent("\(mode.rawValue).json")),
              let record = try? JSONDecoder().decode(Record.self, from: data), record.version == version else { return nil }
        let open = mode == .replace ? cleanURL(for: url, in: folder) : url
        guard FileManager.default.fileExists(atPath: open.path),
              let project = VideoEditorDocument.externalProjectDirectory(for: open),
              FileManager.default.fileExists(atPath: project.appendingPathComponent(CursorTelemetry.filename).path)
        else { return nil }
        return open
    }

    static func run(url: URL, mode: PointerMode, force: Bool = false, cancellation: MediaExportCancellation,
                    progress: @escaping @Sendable (Double) -> Void, dump: URL? = nil,
                    completion: @escaping @MainActor (Result<PointerOutcome, Error>) -> Void) {
        if !force, let cached = cachedOpenURL(for: url, mode: mode) {
            completion(.success(PointerOutcome(openURL: cached, summary: "cached")))
            return
        }
        guard let folder = cacheFolder(for: url) else {
            completion(.failure(CocoaError(.fileWriteUnknown)))
            return
        }
        let templates = Dictionary(uniqueKeysWithValues: PointerTracker.scaleGrid.map { ($0, PointerTemplates.make(scale: $0)) })
        let artwork = PointerTemplates.artwork()
        let hiddenPNG = PointerTemplates.transparentPNG()
        let clean = cleanURL(for: url, in: folder)

        Task.detached(priority: .userInitiated) {
            do {
                let asset = AVURLAsset(url: url)
                let trackShare = mode == .replace ? 0.45 : 1.0
                let track = try await PointerTracker.track(asset: asset, templates: templates, cancellation: cancellation) {
                    progress($0 * trackShare)
                }
                let inferred = PointerEvents.infer(track)
                let telemetry = try PointerEvents.telemetry(for: track, inferred: inferred, artwork: artwork,
                                                            hiddenPNG: hiddenPNG, pointerRemovedFromVideo: mode == .replace)
                if let dump { try? Self.writeDump(track: track, inferred: inferred, to: dump) }

                let openURL: URL
                if mode == .replace {
                    let partial = folder.appendingPathComponent("partial-" + clean.lastPathComponent)
                    try await PointerEraser.erase(asset: asset, track: track, templates: templates[track.scale] ?? [],
                                                  to: partial, cancellation: cancellation) {
                        progress(trackShare + (1 - trackShare) * $0)
                    }
                    try? FileManager.default.removeItem(at: clean)
                    try FileManager.default.moveItem(at: partial, to: clean)
                    openURL = clean
                } else {
                    openURL = url
                }
                guard let project = await VideoEditorDocument.externalProjectDirectory(for: openURL) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
                try telemetry.write(to: project.appendingPathComponent(CursorTelemetry.filename), options: .atomic)

                let visible = Int((track.foundFraction * 100).rounded())
                let summary = "pointer at \(String(format: "%.4g", Double(track.scale)))× in \(visible)% of \(track.frames.count) frames, "
                    + "\(inferred.clicks.count) clicks, \(inferred.typing.count) key presses inferred"
                let record = Record(mode: mode, summary: summary, version: version)
                try JSONEncoder().encode(record).write(to: folder.appendingPathComponent("\(mode.rawValue).json"))
                let outcome = PointerOutcome(openURL: openURL, summary: summary)
                await MainActor.run { completion(.success(outcome)) }
            } catch {
                await MainActor.run { completion(.failure(error)) }
            }
        }
    }

    // MARK: Storage

    private static var cacheRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("macshot Studio/Pointer", isDirectory: true)
    }

    /// One folder per source file version.
    private static func cacheFolder(for url: URL) -> URL? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let identity = "\(url.standardizedFileURL.path)|\(values?.fileSize ?? 0)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        let key = SHA256.hash(data: Data(identity.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        let folder = cacheRoot.appendingPathComponent(key, isDirectory: true)
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) } catch { return nil }
        return folder
    }

    /// Same base name as the original so window titles and export names match.
    private static func cleanURL(for url: URL, in folder: URL) -> URL {
        folder.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".mov")
    }

    nonisolated private static func writeDump(track: PointerTrack, inferred: PointerEvents.Inferred, to url: URL) throws {
        struct Dump: Codable {
            var scale: Double; var width: Int; var height: Int
            var frames: [PointerFrame]; var inferred: PointerEvents.Inferred
        }
        let dump = Dump(scale: Double(track.scale), width: track.width, height: track.height, frames: track.frames, inferred: inferred)
        try JSONEncoder().encode(dump).write(to: url)
    }
}
