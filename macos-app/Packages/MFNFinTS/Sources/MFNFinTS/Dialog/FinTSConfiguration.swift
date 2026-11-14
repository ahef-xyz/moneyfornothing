import Foundation

/// Static facts about a bank's FinTS server.
public struct FinTSBank: Sendable, Equatable {
    public var url: URL
    /// Bankleitzahl.
    public var blz: String
    public var countryCode = "280"

    public init(url: URL, blz: String) {
        self.url = url
        self.blz = blz
    }
}

/// The FinTS product registration (Deutsche Kreditwirtschaft, hbci-zka.de). Banks may reject
/// unregistered products; the registration number must be configured before real use.
public struct FinTSProduct: Sendable, Equatable {
    public var registrationID: String
    public var version: String

    public init(registrationID: String, version: String) {
        self.registrationID = registrationID
        self.version = version
    }

    /// Placeholder until MFN is registered. See STATUS.md.
    public static let unregistered = FinTSProduct(registrationID: "MFN-UNREGISTERED", version: "0.1")
}

/// User credentials for one dialog. `pin` is never logged; `description` is redacted.
public struct FinTSCredentials: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// Benutzerkennung (ING: last 10 digits of the IBAN, DKB: login name).
    public var userID: String
    /// Kunden-ID; empty → `userID` is used.
    public var customerID: String
    public var pin: String

    public init(userID: String, customerID: String = "", pin: String) {
        self.userID = userID
        self.customerID = customerID
        self.pin = pin
    }

    var effectiveCustomerID: String { customerID.isEmpty ? userID : customerID }

    public var description: String { "FinTSCredentials(<redacted>)" }
    public var debugDescription: String { description }
}

/// How the dialog authenticates business transactions.
public enum FinTSTANMechanism: Sendable, Equatable {
    /// Single step (security function `999`), e.g. ING for read-only access.
    case oneStep
    /// Two step (PSD2): `securityFunction` from HITANS (DKB app: `942`), HKTAN segment version.
    case twoStep(securityFunction: String, hktanVersion: Int, tanMedium: String?)

    var securityFunction: String {
        switch self {
        case .oneStep: "999"
        case let .twoStep(function, _, _): function
        }
    }

    /// Security profile `PIN:<n>` in HNVSK/HNSHK: 1 = one-step, 2 = two-step. ING answers a
    /// one-step function (999) under profile 2 with `9010 Ungültiger Signaturaufbau` (2026-11-12,
    /// python-fints sends `PIN:1` there).
    var securityProfileVersion: String {
        switch self {
        case .oneStep: "1"
        case .twoStep: "2"
        }
    }

    var hktanVersion: Int {
        switch self {
        case .oneStep: 6
        case let .twoStep(_, version, _): version
        }
    }
}
