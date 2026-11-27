import Foundation
import MFNCore
import RoutexModels
import RoutexSettlement

/// A failure of a YAXI call in MFN terms (docs/v0.7.0.md section 7).
enum YAXIFailure: Error, Equatable, Sendable {
    /// The stored consent needs the user again (`interruptError`): run the interactive flow.
    case consentNeeded
    /// The bank does not offer this period (`periodOutOfBounds`).
    case periodOutOfBounds
    case connector(ConnectorError)
}

enum YAXIErrors {
    /// How long MFN waits after `accessExceeded` before an automatic sync tries again.
    static let accessExceededRetry: TimeInterval = 6 * 60 * 60

    static func map(_ error: any Error) -> YAXIFailure {
        switch error {
        case let failure as YAXIFailure:
            return failure
        case let connector as ConnectorError:
            return .connector(connector)
        case let routex as RoutexError:
            return map(routex)
        case is KeySettlementError:
            // The enclave did not prove what it runs: never fall back, never send anything.
            YAXIMapper.log.error("YAXI: Attestierung fehlgeschlagen")
            return .connector(.formatChanged(detail: "yaxi attestation"))
        case is CancellationError:
            return .connector(.cancelled)
        case let urlError as URLError:
            return .connector(urlError.code == .cancelled ? .cancelled : .bankUnavailable)
        default:
            YAXIMapper.log.error("YAXI: unerwarteter Fehler \(String(describing: type(of: error)), privacy: .public)")
            return .connector(.formatChanged(detail: "yaxi"))
        }
    }

    static func map(_ error: RoutexError) -> YAXIFailure {
        // Case name and codes only: `userMessage` can carry text from the bank.
        YAXIMapper.log.notice("YAXI: \(name(of: error), privacy: .public)")
        switch error {
        case .interruptError:
            return .consentNeeded
        case .periodOutOfBounds:
            return .periodOutOfBounds
        case .invalidCredentials, .unauthorized, .serviceBlocked:
            return .connector(.authFailed)
        case .accessExceeded:
            return .connector(.rateLimited(retryAfter: accessExceededRetry))
        case .canceled:
            return .connector(.cancelled)
        case .ticketError:
            return .connector(.formatChanged(detail: "yaxi ticket"))
        case .unexpectedValue:
            return .connector(.formatChanged(detail: "yaxi value"))
        case .unsupportedProduct, .paymentFailed:
            // Payment-only errors; MFN never starts a payment.
            return .connector(.formatChanged(detail: "yaxi unexpected"))
        case let .unrecognizedResponse(status, _):
            switch status {
            case 429: return .connector(.rateLimited(retryAfter: accessExceededRetry))
            // Key or infrastructure problem, not the bank.
            case 401, 403: return .connector(.formatChanged(detail: "yaxi http \(status)"))
            default: return .connector(.bankUnavailable)
            }
        case .providerError, .unexpectedError, .notFound:
            return .connector(.bankUnavailable)
        }
    }

    static func name(of error: RoutexError) -> String {
        switch error {
        case .unexpectedError: "unexpectedError"
        case .canceled: "canceled"
        case .invalidCredentials: "invalidCredentials"
        case let .serviceBlocked(code, _): "serviceBlocked \(code.map { "\($0)" } ?? "-")"
        case .unauthorized: "unauthorized"
        case .accessExceeded: "accessExceeded"
        case .periodOutOfBounds: "periodOutOfBounds"
        case .unsupportedProduct: "unsupportedProduct"
        case .paymentFailed: "paymentFailed"
        case .unexpectedValue: "unexpectedValue"
        case let .ticketError(_, code): "ticketError \(code)"
        case let .providerError(code, _): "providerError \(code.map { "\($0)" } ?? "-")"
        case .interruptError: "interruptError"
        case .notFound: "notFound"
        case let .unrecognizedResponse(status, _): "unrecognizedResponse \(status)"
        }
    }
}
