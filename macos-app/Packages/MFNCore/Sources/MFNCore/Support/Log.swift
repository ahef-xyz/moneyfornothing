import os

/// Central loggers. Subsystem is fixed; categories per area.
///
/// Redaction rule: PIN, TAN, passwords, cookies, tokens, IBANs and account numbers are always
/// interpolated with `privacy: .private` (or not at all). `MFNConformance` checks this.
public enum Log {
    public static let subsystem = "xyz.ahef.mfn"

    public static func logger(_ category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }

    public static let core = logger("core")
    public static let sync = logger("sync")
    public static let store = logger("store")
    public static let keychain = logger("keychain")
}
