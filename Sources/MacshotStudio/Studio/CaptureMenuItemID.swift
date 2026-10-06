import Cocoa

// Copied verbatim from upstream AppDelegate.swift (Settings references it).
enum CaptureMenuItemID: String, CaseIterable {
    case captureArea = "captureArea"
    case captureScreen = "captureScreen"
    case captureOCR = "captureOCR"
    case quickCapture = "quickCapture"
    case captureLastArea = "captureLastArea"
    case scrollCapture = "scrollCapture"

    static let userDefaultsKey = "captureMenuItemOrder"
    static let defaultOrder: [CaptureMenuItemID] = [
        .captureArea,
        .captureScreen,
        .captureOCR,
        .quickCapture,
        .captureLastArea,
        .scrollCapture,
    ]

    var title: String {
        switch self {
        case .captureArea: return L("Capture Area")
        case .captureScreen: return L("Capture Screen")
        case .captureOCR: return L("Capture OCR & QR")
        case .quickCapture: return L("Quick Capture")
        case .captureLastArea: return L("Capture Last Area")
        case .scrollCapture: return L("Scroll Capture")
        }
    }

    var symbolName: String {
        switch self {
        case .captureArea: return "crop"
        case .captureScreen: return "desktopcomputer"
        case .captureOCR: return "text.viewfinder"
        case .quickCapture: return "square.and.arrow.down"
        case .captureLastArea: return "arrow.counterclockwise.circle"
        case .scrollCapture: return "scroll"
        }
    }

    var hotkeySlot: HotkeyManager.HotkeySlot {
        switch self {
        case .captureArea: return .captureArea
        case .captureScreen: return .captureFullScreen
        case .captureOCR: return .captureOCR
        case .quickCapture: return .quickCapture
        case .captureLastArea: return .captureLastArea
        case .scrollCapture: return .scrollCapture
        }
    }

    static func orderedItems(defaults: UserDefaults = .standard) -> [CaptureMenuItemID] {
        let saved = defaults.stringArray(forKey: userDefaultsKey) ?? []
        var result: [CaptureMenuItemID] = []
        for rawValue in saved {
            guard let item = CaptureMenuItemID(rawValue: rawValue), !result.contains(item) else { continue }
            result.append(item)
        }
        for item in defaultOrder where !result.contains(item) {
            result.append(item)
        }
        return result
    }

    static func saveOrder(_ items: [CaptureMenuItemID], defaults: UserDefaults = .standard) {
        let sanitized = items.filter { defaultOrder.contains($0) }
        let completed = sanitized + defaultOrder.filter { !sanitized.contains($0) }
        defaults.set(completed.map(\.rawValue), forKey: userDefaultsKey)
    }

    static func resetOrder(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: userDefaultsKey)
    }
}
