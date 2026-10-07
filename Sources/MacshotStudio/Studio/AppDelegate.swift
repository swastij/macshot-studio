import Cocoa
import UniformTypeIdentifiers

/// Stand-in for macshot's menu-bar AppDelegate. macshot Studio is a regular
/// dock app whose only job is opening video files in macshot's video editor.
/// The members other upstream files reach for exist here with the same
/// names, mostly as no-ops since capture, pins and uploads are not part of it.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var pendingOpenURLs: [URL] = []
    private var isReady = false
    private var errorToastController: UploadToastController?

    // MARK: Lifecycle

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.mainMenu = makeMainMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        isReady = true
        // Paths passed on the command line: `macshot-studio clip.mov`.
        let cliURLs = CommandLine.arguments.dropFirst()
            .filter { !$0.hasPrefix("-") }
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        let urls = pendingOpenURLs + cliURLs
        pendingOpenURLs = []
        if urls.isEmpty {
            showEmptyEditor()
        } else {
            urls.forEach(openVideo)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard isReady else { pendingOpenURLs.append(contentsOf: urls); return }
        urls.forEach(openVideo)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showEmptyEditor() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: Opening

    private var emptyEditor: EmptyEditorWindowController?

    /// The editor with no video yet: drop a file or choose one.
    func showEmptyEditor() {
        if emptyEditor?.window?.isVisible != true {
            emptyEditor = EmptyEditorWindowController { [weak self] url in self?.openVideo(url) }
        }
        emptyEditor?.showWindow(nil)
        emptyEditor?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie, .movie, .video, .gif]
        panel.message = L("Choose a video to open in macshot editor")
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK else { return }
            panel.urls.forEach(self.openVideo)
        }
    }

    private func openVideo(_ url: URL) {
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        PointerOpening.open(url)
    }

    @objc private func openRedetecting(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie, .movie, .video]
        panel.message = "Choose a video to detect the pointer in again"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            PointerOpening.open(url, forceDetection: true)
        }
    }

    @objc private func choosePointerPreference(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let preference = PointerPreference(rawValue: raw) else { return }
        PointerPreference.current = preference
        refreshPointerMenu()
    }

    private var pointerMenu: NSMenu?

    func refreshPointerMenu() {
        for item in pointerMenu?.items ?? [] {
            guard let raw = item.representedObject as? String else { continue }
            item.state = raw == PointerPreference.current.rawValue ? .on : .off
        }
    }

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appName = "macshot Studio"

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu(appMenu, title: appName))

        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Open Video…", action: #selector(openDocument(_:)), keyEquivalent: "o")
        let recent = NSMenu(title: "Open Recent")
        recent.perform(NSSelectorFromString("_setMenuName:"), with: "NSRecentDocumentsMenu")
        recent.addItem(withTitle: "Clear Menu", action: #selector(NSDocumentController.clearRecentDocuments(_:)), keyEquivalent: "")
        fileMenu.addItem(submenu(recent, title: "Open Recent"))
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenu(fileMenu, title: "File"))

        // Standard edit actions so text fields in the editor get copy/paste/undo.
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu(editMenu, title: "Edit"))

        let pointer = NSMenu(title: "Pointer")
        let header = pointer.addItem(withTitle: "When Opening a Video", action: nil, keyEquivalent: "")
        header.isEnabled = false
        for preference in PointerPreference.allCases {
            let item = pointer.addItem(withTitle: preference.menuTitle, action: #selector(choosePointerPreference(_:)), keyEquivalent: "")
            item.representedObject = preference.rawValue
            item.indentationLevel = 1
        }
        pointer.addItem(.separator())
        pointer.addItem(withTitle: "Open Video and Detect Pointer Again…", action: #selector(openRedetecting(_:)), keyEquivalent: "O")
        pointerMenu = pointer
        main.addItem(submenu(pointer, title: "Pointer"))
        refreshPointerMenu()

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        main.addItem(submenu(windowMenu, title: "Window"))
        NSApp.windowsMenu = windowMenu
        return main
    }

    private func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    // MARK: Upstream hooks used by the video editor

    /// Upstream drops back to a menu-bar accessory and refocuses the previous
    /// app. A dock app just stays put.
    func returnFocusIfNeeded() {
        NSApp.setActivationPolicy(.regular)
        // Last video closed (or failed to open): go back to the empty editor.
        DispatchQueue.main.async { [weak self] in
            let editing = NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) }
            if !editing { self?.showEmptyEditor() }
        }
    }

    func showFailureToast(_ message: String) {
        errorToastController?.dismiss()
        let toast = UploadToastController()
        errorToastController = toast
        toast.onDismiss = { [weak self] in self?.errorToastController = nil }
        toast.show(status: message)
        toast.showError(message: message, asUploadFailure: false)
    }

    // MARK: Upstream hooks for screenshot features Studio doesn't ship

    static let captureSound: NSSound? = nil
    static let statusBarIconModeKey = "statusBarIconMode"
    static let statusBarIconSymbolNameKey = "statusBarIconSymbolName"
    static let editablePointerDefaultsKey = "recordEditablePointer"
    static var recordsEditablePointer: Bool { true }

    static func activateApp(_ app: NSRunningApplication) {
        NSApp.yieldActivation(to: app)
        app.activate()
    }

    static func relaunchApp() {
        let url = Bundle.main.bundleURL
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    func setMenuBarIconVisible(_ visible: Bool) {}
    func refreshStatusBarIcon() {}
    func reapplySettingsAfterImport() {}
    func confirmClearHistory() {}
    func showFloatingThumbnail(image: NSImage, annotationData: CaptureAnnotationData? = nil, historyEntryID: String? = nil) {}
    func refreshThumbnail(for entryID: String, image: NSImage, annotationData: CaptureAnnotationData? = nil) {}
    func runOCR(on image: NSImage) {}
    func uploadImage(_ image: NSImage) {}
    func showPin(image: NSImage) {}
}
