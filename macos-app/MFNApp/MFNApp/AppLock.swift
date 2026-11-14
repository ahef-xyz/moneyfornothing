import AppKit
import LocalAuthentication
import MFNCore
import Observation

/// App lock (CLAUDE.md §6): Touch ID / password at launch, after screen lock and after
/// 5 minutes without input. While locked, `onLock` closes the data and the UI shows `LockView`.
@MainActor
@Observable
final class AppLock {
    static let idleTimeout: Duration = .seconds(5 * 60)

    /// Why MFN is locked, shown on the lock screen.
    enum Cause: Equatable {
        case launch, idle, system, manual
    }

    /// Touch ID usable on this Mac (else the system asks for the Mac password).
    static var biometryAvailable: Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) && context.biometryType == .touchID
    }

    private(set) var isLocked = true
    private(set) var lastError: String?
    private(set) var isAuthenticating = false
    private(set) var cause: Cause = .launch

    /// Called when locking: drop decrypted data and keys from memory.
    var onLock: (@MainActor () -> Void)?
    /// Called after a successful unlock with the evaluated context: reopen the store. The
    /// context is reused for the keychain read of the database key (no second prompt).
    var onUnlock: (@MainActor (sending LAContext) async -> Void)?

    @ObservationIgnored private var lastActivity = ContinuousClock.now
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var eventMonitor: Any?
    @ObservationIgnored private var idleTask: Task<Void, Never>?
    /// Whether the lock screen may ask by itself the next time its window becomes key. Not a
    /// timer: closing the system dialog hands focus back to the window, and that must never
    /// count as the user coming back (a cancel would loop).
    @ObservationIgnored private var autoPromptArmed = true

    func start() {
        let distributed = DistributedNotificationCenter.default()
        observers.append(distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lock(cause: .system) }
        })
        // Screen sleep, fast user switching away from this session, system sleep.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.willSleepNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.lock(cause: .system) }
            })
        }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel, .mouseMoved]) { [weak self] event in
            self?.lastActivity = .now
            return event
        }
        idleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self else { return }
                if !self.isLocked, ContinuousClock.now - self.lastActivity > Self.idleTimeout {
                    self.lock(cause: .idle)
                }
            }
        }
    }

    func lock(cause: Cause = .manual) {
        guard !isLocked else { return }
        self.cause = cause
        // Locked by hand (menu, or "Abbrechen" on the password): no prompt right back.
        autoPromptArmed = cause != .manual
        isLocked = true
        onLock?()
        Log.core.info("App gesperrt")
    }

    /// Locks because the data could not be opened; the message is shown on the lock screen.
    func lock(reason: String) {
        lock()
        lastError = reason
    }

    /// The lock screen's window became key: true if it should ask now (then call `unlock()`).
    /// Each arming allows one automatic prompt. Never over an error, which must stay readable;
    /// the button still works.
    func takeAutoPrompt() -> Bool {
        guard isLocked, !isAuthenticating, autoPromptArmed, lastError == nil else { return false }
        autoPromptArmed = false
        return true
    }

    /// The lock screen's window lost focus while no prompt was open (the system dialog itself
    /// takes focus): coming back may ask again.
    func windowResignedKey() {
        guard !isAuthenticating else { return }
        autoPromptArmed = true
    }

    func unlock() async {
        guard isLocked, !isAuthenticating else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }
        let context = LAContext()
        context.localizedCancelTitle = "Abbrechen"
        do {
            try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "deine Finanzdaten entsperren")
            lastError = nil
            lastActivity = .now
            isLocked = false
            await onUnlock?(context)
            Log.core.info("App entsperrt")
        } catch let error as LAError where error.code == .userCancel || error.code == .appCancel || error.code == .systemCancel {
            // A cancel keeps an earlier error (e.g. the data could not be opened) on screen.
        } catch {
            lastError = error.localizedDescription
        }
    }
}
