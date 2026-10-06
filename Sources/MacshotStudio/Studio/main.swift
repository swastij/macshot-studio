import Cocoa

// Same pixel-exact layer format upstream main.swift sets.
UserDefaults.standard.set(false, forKey: "NSViewUsesAutomaticLayerBackingStores")

MainActor.assumeIsolated {
    _ = NSApplication.shared  // system cursors need the app object
    if StudioCLI.runIfRequested() { return }
    let delegate = AppDelegate()
    NSApplication.shared.delegate = delegate
    withExtendedLifetime(delegate) { NSApplication.shared.run() }
}
