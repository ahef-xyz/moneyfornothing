import AppKit
import SwiftUI

/// App icon variants. `dark` is the bundle's icon (Finder, Launchpad); the others replace the
/// Dock icon while MFN is running – macOS has no alternate bundle icons like iOS.
enum AppIconChoice: String, CaseIterable, Identifiable {
    case dark
    case flat
    case retro

    static let storageKey = "appIcon"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dark: String(localized: "Schwarz")
        case .flat: String(localized: "Violett")
        case .retro: String(localized: "Retro 3D")
        }
    }

    var imageName: String {
        switch self {
        case .dark: "IconDark"
        case .flat: "IconFlat"
        case .retro: "IconRetro"
        }
    }

    /// Icon for in-app use (lock screen, password screen, About). Read from the choice, not from
    /// `NSApp.applicationIconImage`: that is not observable and still the bundle icon on first render.
    @MainActor
    var image: NSImage {
        NSImage(named: imageName) ?? NSApplication.shared.applicationIconImage
    }

    @MainActor
    func apply() {
        // `nil` restores the bundle icon. `NSApp` is nil while `AppModel.init` runs (the
        // `@Observable` setter fires `didSet` there); `RootView` applies the choice again on appear.
        NSApp?.applicationIconImage = self == .dark ? nil : NSImage(named: imageName)
    }
}

/// Three selectable thumbnails. Selection is shown by ring and checkmark, not colour alone.
struct AppIconPicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 18) {
            ForEach(AppIconChoice.allCases) { option in
                let selected = option == model.appIcon
                Button {
                    model.appIcon = option
                } label: {
                    VStack(spacing: 6) {
                        Image(option.imageName)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 72, height: 72)
                            .padding(4)
                            .overlay {
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 2.5)
                            }
                        Label(option.title, systemImage: selected ? "checkmark.circle.fill" : "circle")
                            .font(.callout)
                            .foregroundStyle(selected ? .primary : .secondary)
                    }
                    .padding(6)
                    .contentShape(Rectangle())     // whole tile is clickable, not only its opaque pixels
                }
                .buttonStyle(.plain)
                .accessibilityLabel("App-Symbol \(option.title)")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }
}
