#if DEBUG
import AppKit
import MFNCore

/// Reproducible website screenshots from the demo dataset (debug builds only, never in release).
/// Driven by `scripts/website-screenshots`: launch once with
///
///     open --env MFN_DEMO=1 --env MFN_SHOT=1 --env MFN_SHOT_SIZE=1440x900 MFN.app
///
/// then switch view and appearance in the running app with a distributed notification
/// `xyz.ahef.mfn.screenshot` whose object is `<view>,<light|dark>`. `<view>`: `overview`, `all`,
/// `review`, `pending`, an account ID (e.g. `mock-dkb-depot`) or `forecast:<account ID>` (the
/// account with its forecast sheet open). One launch, so the app lock asks
/// only once. Only honoured together with `MFN_DEMO`, so real data never ends up in a screenshot;
/// demo banks then sync without approval sheets (`AppModel.demo`).
@MainActor
enum ScreenshotMode {
    static let notification = Notification.Name("xyz.ahef.mfn.screenshot")
    static let ready = Notification.Name("xyz.ahef.mfn.screenshot.ready")
    private static let environment = ProcessInfo.processInfo.environment
    private static var started = false

    static var isActive: Bool {
        guard let demo = environment["MFN_DEMO"]?.lowercased(), !["", "0", "false", "no"].contains(demo) else { return false }
        return environment["MFN_SHOT"] == "1"
    }

    /// Call once the main view is visible (unlocked): sizes the window, syncs, starts listening.
    static func start(with model: AppModel) {
        guard isActive, !started, !model.lock.isLocked else { return }
        started = true
        if let size = environment["MFN_SHOT_SIZE"], let window = mainWindow {
            let parts = size.split(separator: "x").compactMap { Double($0) }
            if parts.count == 2 {
                window.setContentSize(NSSize(width: parts[0], height: parts[1]))
                window.center()
            }
        }
        model.syncAll()
        // Tells the script the app is unlocked (it cannot look into the sandbox container).
        DistributedNotificationCenter.default().postNotificationName(ready, object: nil, userInfo: nil, deliverImmediately: true)
        // Sandboxed apps receive distributed notifications with an object string (no userInfo).
        DistributedNotificationCenter.default().addObserver(forName: notification, object: nil, queue: .main) { note in
            let request = note.object as? String
            MainActor.assumeIsolated { show(request, in: model) }
        }
    }

    private static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.canBecomeMain }
    }

    private static func show(_ request: String?, in model: AppModel) {
        guard let parts = request?.split(separator: ","), parts.count == 2 else { return }
        NSApp.appearance = NSAppearance(named: parts[1] == "dark" ? .darkAqua : .aqua)
        if parts[0].hasPrefix("forecast:") {
            let id = AccountID(rawValue: String(parts[0].dropFirst("forecast:".count)))
            model.selection = .account(id)
            if model.forecastPanel?.account.id != id, let account = model.account(id) { model.showForecast(for: account) }
            mainWindow?.makeKeyAndOrderFront(nil)
            return
        }
        model.forecastPanel = nil
        model.selection = switch parts[0] {
        case "overview": .overview
        case "all": .allAccounts
        case "review": .review
        case "pending": .pending
        default: .account(AccountID(rawValue: String(parts[0])))
        }
        mainWindow?.makeKeyAndOrderFront(nil)
    }
}
#endif
