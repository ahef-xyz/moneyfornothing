import AppKit
import SwiftUI

/// The public website. Static: MFN never loads anything from it here; the link only opens in
/// the browser when clicked.
enum Website {
    static let label = "moneyfornothing.app"
    static let url = URL(string: "https://moneyfornothing.app")
}

enum AppVersion {
    static var text: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "–"
        let build = info["CFBundleVersion"] as? String ?? "–"
        return String(localized: "Version \(version) (\(build))")
    }
}

/// "Über MoneyForNothing": own window from the app menu and the "Über" tab in Settings.
struct AboutView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                Image(nsImage: model.appIcon.image)
                    .resizable()
                    .frame(width: 96, height: 96)
                    .accessibilityHidden(true)
                Text("MoneyForNothing")
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(AppVersion.text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text("Read-only Multibanking: lokal, ohne Gebühren, ohne Cloud.")
                    .font(.callout)
                    .multilineTextAlignment(.center)
            }

            if let url = Website.url {
                Link(Website.label, destination: url)
                    .font(.callout)
                    .accessibilityLabel("Website von MoneyForNothing")
            }

            Text("Deine Bankdaten bleiben auf diesem Mac.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(width: 420)
    }
}

/// Replaces the standard About panel in the app menu.
struct AboutCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Über MoneyForNothing") { openWindow(id: AboutView.windowID) }
    }
}

extension AboutView {
    static let windowID = "about"
}
