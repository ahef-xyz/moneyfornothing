import Sparkle
import SwiftUI

/// Sparkle updater, owned by the App struct. Only runs in official builds that carry a feed URL
/// and a public key (`MFN_APPCAST_URL`, `MFN_SPARKLE_PUBLIC_KEY`); self-built apps leave both empty
/// and get no updater and no menu item. Automatic checks stay off until the user agrees (Sparkle asks
/// on the second launch); no system profiling.
@MainActor
@Observable
final class AppUpdater {
    let controller: SPUStandardUpdaterController?

    var isAvailable: Bool { controller != nil }

    init() {
        func setting(_ key: String) -> String {
            (Bundle.main.object(forInfoDictionaryKey: key) as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        let configured = URL(string: setting("SUFeedURL")) != nil
            && !setting("SUFeedURL").isEmpty && !setting("SUPublicEDKey").isEmpty
        controller = configured
            ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
            : nil
    }
}

/// "Nach Updates suchen …" in the app menu; hidden without an updater.
struct CheckForUpdatesCommand: View {
    let updater: AppUpdater
    @State private var canCheck = true

    var body: some View {
        if let controller = updater.controller {
            Button("Nach Updates suchen …") { controller.checkForUpdates(nil) }
                .disabled(!canCheck)
                .onReceive(controller.updater.publisher(for: \.canCheckForUpdates)) { canCheck = $0 }
        }
    }
}
