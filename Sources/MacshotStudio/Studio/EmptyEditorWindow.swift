import AppKit
import UniformTypeIdentifiers

/// The editor before a video is open: same window and layout as the video
/// editor, with a drop zone where the preview goes. Opening a video hands
/// over to the real editor, which takes this window's place.
@MainActor
final class EmptyEditorWindowController: NSWindowController, NSWindowDelegate {
    private let onOpen: (URL) -> Void
    private var editorObserver: NSObjectProtocol?

    init(onOpen: @escaping (URL) -> Void) {
        self.onOpen = onOpen
        let window = NSWindow(contentRect: Self.defaultFrame(), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = VideoEditorStyle.window
        window.minSize = NSSize(width: 980, height: 640)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary]
        window.title = "macshot Studio"
        // Open where the editor last was, without taking over its saved frame.
        window.setFrameUsingName(Self.editorFrameName)
        super.init(window: window)
        window.delegate = self
        window.contentView = EmptyEditorView(onOpen: { [weak self] url in self?.onOpen(url) },
                                             onChoose: { [weak self] in self?.choose() })

        // The real editor appears once the video is prepared; then step aside.
        editorObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil,
                                                                queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let window = note.object as? NSWindow, window.windowController is VideoEditorWindowController else { return }
                self?.close()
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let editorObserver { NotificationCenter.default.removeObserver(editorObserver) }
    }

    static let editorFrameName = "macshot.videoEditor"

    /// The video editor's default size, for a first launch.
    private static func defaultFrame() -> NSRect {
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(visible.width * 0.9, max(1100, visible.width * 0.84))
        let height = min(visible.height * 0.92, max(720, visible.height * 0.86))
        return NSRect(x: visible.midX - width / 2, y: visible.midY - height / 2, width: width, height: height)
    }

    func choose() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = EmptyEditorView.videoTypes
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.onOpen(url)
        }
    }

    func windowWillClose(_ notification: Notification) {
        window?.saveFrame(usingName: Self.editorFrameName)
    }
}

/// Editor-shaped layout: top bar, inspector rail, stage with the drop zone,
/// and an empty timeline.
@MainActor
private final class EmptyEditorView: NSView {
    static let videoTypes: [UTType] = [.mpeg4Movie, .quickTimeMovie, .movie, .video, .gif]

    private let onOpen: (URL) -> Void
    private let dropZone: DropZoneView

    init(onOpen: @escaping (URL) -> Void, onChoose: @escaping () -> Void) {
        self.onOpen = onOpen
        dropZone = DropZoneView(onChoose: onChoose)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = VideoEditorStyle.window.cgColor
        registerForDraggedTypes([.fileURL])
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        // Top bar: title in the middle, export actions (unavailable yet) on the right.
        let topBar = NSView()
        topBar.translatesAutoresizingMaskIntoConstraints = false
        let title = VideoEditorStyle.label("macshot Studio", size: 13, weight: .semibold)
        let subtitle = VideoEditorStyle.label("No video open", size: 11, color: VideoEditorStyle.textTertiary)
        let titles = NSStackView(views: [title, subtitle])
        titles.orientation = .vertical
        titles.spacing = 1
        titles.translatesAutoresizingMaskIntoConstraints = false
        let copy = VideoPillButton(title: L("Copy"), symbol: "doc.on.doc", target: nil, action: nil)
        let export = VideoPillButton(title: L("Export"), symbol: "square.and.arrow.up", target: nil, action: nil)
        export.fill = VideoEditorStyle.accent
        export.textColor = .white
        for button in [copy, export] {
            button.isEnabled = false
            button.alphaValue = 0.4
            button.translatesAutoresizingMaskIntoConstraints = false
        }
        for view in [titles, copy, export] as [NSView] { topBar.addSubview(view) }

        // Inspector: the section rail, dimmed, and a hint where settings go.
        let inspector = NSView()
        inspector.translatesAutoresizingMaskIntoConstraints = false
        inspector.wantsLayer = true
        inspector.layer?.backgroundColor = VideoEditorStyle.panel.cgColor
        let rail = NSStackView()
        rail.orientation = .vertical
        rail.spacing = 22
        rail.translatesAutoresizingMaskIntoConstraints = false
        for symbol in ["photo.on.rectangle.angled", "cursorarrow.rays", "plus.magnifyingglass", "keyboard",
                       "person.crop.square", "captions.bubble"] {
            let icon = NSImageView(image: VideoEditorStyle.symbol(symbol, size: 17) ?? NSImage())
            icon.contentTintColor = VideoEditorStyle.textTertiary
            rail.addArrangedSubview(icon)
        }
        let hint = VideoEditorStyle.label("Open a video to edit its background,\npointer, zooms, captions and more.",
                                          size: 12, color: VideoEditorStyle.textTertiary)
        hint.maximumNumberOfLines = 0
        hint.lineBreakMode = .byWordWrapping
        inspector.addSubview(rail)
        inspector.addSubview(hint)
        let divider = NSBox()
        divider.boxType = .custom
        divider.borderWidth = 0
        divider.fillColor = VideoEditorStyle.separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        // Stage with the drop zone.
        let stage = NSView()
        stage.translatesAutoresizingMaskIntoConstraints = false
        stage.wantsLayer = true
        stage.layer?.backgroundColor = VideoEditorStyle.stage.cgColor
        dropZone.translatesAutoresizingMaskIntoConstraints = false
        stage.addSubview(dropZone)

        // Empty timeline.
        let timeline = NSView()
        timeline.translatesAutoresizingMaskIntoConstraints = false
        timeline.wantsLayer = true
        timeline.layer?.backgroundColor = VideoEditorStyle.panel.cgColor
        let timelineHint = VideoEditorStyle.label("The timeline appears here once a video is open",
                                                  size: 12, color: VideoEditorStyle.textTertiary)
        timeline.addSubview(timelineHint)

        for view in [topBar, inspector, divider, stage, timeline] { addSubview(view) }
        let inspectorWidth = VideoInspectorView.railWidth + VideoInspectorView.panelWidth
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: topAnchor),
            topBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 52),
            titles.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
            titles.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            export.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -16),
            export.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            export.heightAnchor.constraint(equalToConstant: 30),
            copy.trailingAnchor.constraint(equalTo: export.leadingAnchor, constant: -8),
            copy.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            copy.heightAnchor.constraint(equalToConstant: 30),

            inspector.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            inspector.leadingAnchor.constraint(equalTo: leadingAnchor),
            inspector.widthAnchor.constraint(equalToConstant: inspectorWidth),
            inspector.bottomAnchor.constraint(equalTo: timeline.topAnchor),
            rail.topAnchor.constraint(equalTo: inspector.topAnchor, constant: 24),
            rail.centerXAnchor.constraint(equalTo: inspector.leadingAnchor, constant: VideoInspectorView.railWidth / 2),
            hint.topAnchor.constraint(equalTo: inspector.topAnchor, constant: 28),
            hint.leadingAnchor.constraint(equalTo: inspector.leadingAnchor, constant: VideoInspectorView.railWidth + 24),
            hint.trailingAnchor.constraint(lessThanOrEqualTo: inspector.trailingAnchor, constant: -20),
            divider.leadingAnchor.constraint(equalTo: inspector.trailingAnchor),
            divider.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            divider.bottomAnchor.constraint(equalTo: timeline.topAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),

            stage.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            stage.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            stage.trailingAnchor.constraint(equalTo: trailingAnchor),
            stage.bottomAnchor.constraint(equalTo: timeline.topAnchor),
            dropZone.centerXAnchor.constraint(equalTo: stage.centerXAnchor),
            dropZone.centerYAnchor.constraint(equalTo: stage.centerYAnchor),
            dropZone.widthAnchor.constraint(equalTo: stage.widthAnchor, multiplier: 0.62),
            dropZone.heightAnchor.constraint(equalTo: stage.heightAnchor, multiplier: 0.62),

            timeline.leadingAnchor.constraint(equalTo: leadingAnchor),
            timeline.trailingAnchor.constraint(equalTo: trailingAnchor),
            timeline.bottomAnchor.constraint(equalTo: bottomAnchor),
            timeline.heightAnchor.constraint(equalToConstant: 282),
            timelineHint.centerXAnchor.constraint(equalTo: timeline.centerXAnchor),
            timelineHint.centerYAnchor.constraint(equalTo: timeline.centerYAnchor),
        ])
    }

    // MARK: Drag and drop

    private func videoURL(from info: NSDraggingInfo) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
        return urls.first { url in
            guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
            return Self.videoTypes.contains { type.conforms(to: $0) }
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let ok = videoURL(from: sender) != nil
        dropZone.isTargeted = ok
        return ok ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { dropZone.isTargeted = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropZone.isTargeted = false
        guard let url = videoURL(from: sender) else { return false }
        onOpen(url)
        return true
    }
}

/// Dashed drop target with a Choose button.
@MainActor
private final class DropZoneView: NSView {
    var isTargeted = false { didSet { needsDisplay = true } }

    init(onChoose: @escaping () -> Void) {
        super.init(frame: .zero)
        let icon = NSImageView(image: VideoEditorStyle.symbol("film.stack", size: 40, weight: .light) ?? NSImage())
        icon.contentTintColor = VideoEditorStyle.textSecondary
        let title = VideoEditorStyle.label("Drop a video here", size: 17, weight: .semibold)
        let detail = VideoEditorStyle.label("MP4, MOV, M4V or GIF. Your original file is never changed.",
                                            size: 12, color: VideoEditorStyle.textTertiary)
        let choose = VideoPillButton(title: "Choose Video…", symbol: "folder", target: nil, action: nil)
        choose.fill = VideoEditorStyle.accent
        choose.textColor = .white
        let handler = ClosureTarget(onChoose)
        choose.target = handler
        choose.action = #selector(ClosureTarget.run)
        objc_setAssociatedObject(choose, "studio.choose", handler, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        choose.heightAnchor.constraint(equalToConstant: 34).isActive = true
        let stack = NSStackView(views: [icon, title, detail, choose])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.setCustomSpacing(18, after: detail)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1.5, dy: 1.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 16, yRadius: 16)
        (isTargeted ? VideoEditorStyle.accent.withAlphaComponent(0.12) : NSColor(white: 1, alpha: 0.025)).setFill()
        path.fill()
        path.lineWidth = isTargeted ? 2.5 : 1.5
        path.setLineDash([7, 6], count: 2, phase: 0)
        (isTargeted ? VideoEditorStyle.accent : NSColor(white: 1, alpha: 0.18)).setStroke()
        path.stroke()
    }
}

private final class ClosureTarget: NSObject {
    private let block: () -> Void
    init(_ block: @escaping () -> Void) { self.block = block }
    @objc func run() { block() }
}
