import AppKit
import SwiftUI

/// Light, dark or follow the system. Stored in `UserDefaults` under `appearance`.
///
/// Applied through `NSApp.appearance` rather than `preferredColorScheme`: on macOS the latter
/// does not switch back reliably when returning to "Automatisch", and it would not reach
/// sheets, menus and the Settings window.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let storageKey = "appearance"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: String(localized: "Automatisch")
        case .light: String(localized: "Hell")
        case .dark: String(localized: "Dunkel")
        }
    }

    @MainActor
    func apply() {
        // `NSApp` is nil during `AppModel.init`; `RootView` applies the mode again on appear.
        NSApp?.appearance = switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// Picker used in the "Darstellung" menu and in Settings. The model is passed in because
/// menu commands have no SwiftUI environment.
struct AppearancePicker: View {
    @Bindable var model: AppModel

    var body: some View {
        Picker("Erscheinungsbild", selection: $model.appearance) {
            ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) }
        }
    }
}
