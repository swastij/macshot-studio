import AppKit

/// How Studio treats the pointer in videos it opens.
enum PointerPreference: String, CaseIterable {
    case ask, replace, track, off

    static let defaultsKey = "pointerDetection"

    static var current: PointerPreference {
        get { UserDefaults.standard.string(forKey: defaultsKey).flatMap(PointerPreference.init) ?? .ask }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    var menuTitle: String {
        switch self {
        case .ask: return "Ask When Opening"
        case .replace: return "Replace Pointer (Restyle + Zoom)"
        case .track: return "Track Pointer Only (Zoom)"
        case .off: return "Don't Detect"
        }
    }
}

/// Opens a video in the editor, running pointer detection first when wanted.
@MainActor
enum PointerOpening {
    static func open(_ url: URL, forceDetection: Bool = false) {
        guard url.pathExtension.lowercased() != "gif" else { return openEditor(url) }

        // Reuse earlier results without asking.
        if !forceDetection {
            for mode in [PointerMode.replace, .track] {
                if let cached = PointerAnalysis.cachedOpenURL(for: url, mode: mode) { return openEditor(cached) }
            }
        }
        let mode: PointerMode?
        switch PointerPreference.current {
        case .replace: mode = .replace
        case .track: mode = .track
        case .off: mode = forceDetection ? ask(url) : nil
        case .ask: mode = ask(url)
        }
        guard let mode else { return openEditor(url) }
        detect(url, mode: mode)
    }

    private static func ask(_ url: URL) -> PointerMode? {
        let alert = NSAlert()
        alert.messageText = "Detect the pointer in “\(url.lastPathComponent)”?"
        alert.informativeText = """
            Replace Pointer removes the recorded pointer so the editor can draw its own: restyle, resize, \
            smooth or hide it, add click effects, and use Auto Zoom from detected clicks.

            Track Only keeps the recorded pointer and enables Auto Zoom and zooms that follow it.

            Works with the standard macOS pointer. Results are saved for next time.
            """
        alert.addButton(withTitle: "Replace Pointer")
        alert.addButton(withTitle: "Track Only")
        alert.addButton(withTitle: "Skip")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Always do this"
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        let choice: PointerMode? = switch response {
        case .alertFirstButtonReturn: .replace
        case .alertSecondButtonReturn: .track
        default: nil
        }
        if alert.suppressionButton?.state == .on {
            PointerPreference.current = choice.map { $0 == .replace ? .replace : .track } ?? .off
            (NSApp.delegate as? AppDelegate)?.refreshPointerMenu()
        }
        return choice
    }

    private static func detect(_ url: URL, mode: PointerMode) {
        var outcome: PointerOutcome?
        let job = MediaExportCoordinator.shared.start(
            title: url.lastPathComponent,
            status: mode == .replace ? "Finding and removing the pointer…" : "Finding the pointer…",
            operation: { cancellation, progress in
                outcome = try await withCheckedThrowingContinuation { continuation in
                    PointerAnalysis.run(url: url, mode: mode, force: true, cancellation: cancellation, progress: progress) {
                        continuation.resume(with: $0)
                    }
                }
            },
            completion: { result in
                switch result {
                case .success:
                    if let outcome { openEditor(outcome.openURL) }
                case .failure(let error) where error is CancellationError:
                    break
                case .failure(let error):
                    let alert = NSAlert()
                    alert.messageText = "Pointer detection didn't work for this video"
                    alert.informativeText = error.localizedDescription
                        + "\n\nThe video will open without pointer data. Detection needs the standard macOS pointer, visible and moving."
                    alert.runModal()
                    openEditor(url)
                }
            })
        MediaExportProgressController.show(for: job)
    }

    private static func openEditor(_ url: URL) {
        // Never let the editor delete the file it opens.
        VideoEditorWindowController.open(url: url, deleteOnClose: false)
    }
}
