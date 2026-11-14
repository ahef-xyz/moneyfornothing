import Foundation
import MFNCore

/// Builders for the request segments MFN uses. Read-only transactions only – never add order
/// segments (`HKCCS`, `HKDSE` …): MFN does not move money.
///
/// Segment numbers are assigned by `FinTSMessage.build`; version choice by the caller from BPD.
public enum FinTSSegments {
    // MARK: Dialog

    /// Identification. Anonymous: user `9999999999`, system ID `0`, no system ID required.
    public static func identification(bank: FinTSBank, customerID: String, systemID: String, anonymous: Bool = false) -> FinTSSegment {
        FinTSSegment(type: "HKIDN", version: 2, elements: [
            FinTSDataElement(texts: [bank.countryCode, bank.blz]),
            FinTSDataElement(stringLiteral: anonymous ? "9999999999" : customerID),
            FinTSDataElement(stringLiteral: anonymous ? "0" : systemID),
            FinTSDataElement(stringLiteral: anonymous ? "0" : "1"),
        ])
    }

    /// Processing preparation: BPD/UPD versions known to the client, product registration.
    public static func processingPreparation(bpdVersion: Int, updVersion: Int, product: FinTSProduct) -> FinTSSegment {
        FinTSSegment(type: "HKVVB", version: 3, elements: [
            FinTSDataElement(stringLiteral: String(bpdVersion)),
            FinTSDataElement(stringLiteral: String(updVersion)),
            "0",
            FinTSDataElement(stringLiteral: product.registrationID),
            FinTSDataElement(stringLiteral: product.version),
        ])
    }

    /// Synchronisation, mode 0 = request a new customer system ID.
    public static func synchronization() -> FinTSSegment {
        FinTSSegment(type: "HKSYN", version: 3, elements: ["0"])
    }

    /// TAN process 4: "order with TAN" announcement for `referenceSegment` (PSD2 dialog init
    /// uses `HKIDN`). The TAN medium is required by some banks for two-step methods.
    public static func tanProcess4(version: Int, referenceSegment: String, tanMedium: String? = nil) -> FinTSSegment {
        var elements: [FinTSDataElement] = ["4", FinTSDataElement(stringLiteral: referenceSegment)]
        if let tanMedium {
            // Elements 3–10 are empty for process 4; the TAN medium name is element 11 (v6 and v7).
            elements += Array(repeating: .empty, count: 8)
            elements.append(FinTSDataElement(stringLiteral: tanMedium))
        }
        return FinTSSegment(type: "HKTAN", version: version, elements: elements)
    }

    /// TAN process S: status poll for a decoupled approval (`orderReference` from `HITAN`).
    /// HKTAN v7: 1 process, 2 segment ref, 3 account, 4 order hash, 5 order reference,
    /// 6 further TAN follows → `S++++<ref>+N`.
    public static func tanStatusPoll(version: Int, orderReference: String) -> FinTSSegment {
        FinTSSegment(type: "HKTAN", version: version, elements: [
            "S", .empty, .empty, .empty,
            FinTSDataElement(stringLiteral: orderReference),
            "N",
        ])
    }

    public static func dialogEnd(dialogID: String) -> FinTSSegment {
        FinTSSegment(type: "HKEND", version: 1, elements: [FinTSDataElement(stringLiteral: dialogID)])
    }

    // MARK: Business (read-only)

    /// SEPA account information (IBAN/BIC for all accounts).
    public static func sepaAccounts(version: Int = 1) -> FinTSSegment {
        FinTSSegment(type: "HKSPA", version: version, elements: [])
    }

    /// Balance. v7 uses KTI, v5/v6 KTV.
    public static func balance(version: Int, account: FinTSAccount, touchdown: String? = nil) -> FinTSSegment {
        FinTSSegment(type: "HKSAL", version: version, elements: [
            version >= 7 ? account.kti : account.ktv,
            "N",
            .empty,
            touchdown.map { FinTSDataElement(stringLiteral: $0) } ?? .empty,
        ])
    }

    /// Transactions as MT940. v7 uses KTI, v5/v6 KTV. Dates as `yyyyMMdd`.
    public static func statementMT940(version: Int, account: FinTSAccount, from: BankDay?, to: BankDay?, touchdown: String? = nil) -> FinTSSegment {
        FinTSSegment(type: "HKKAZ", version: version, elements: [
            version >= 7 ? account.kti : account.ktv,
            "N",
            from.map { FinTSDataElement(stringLiteral: fintsDate($0)) } ?? .empty,
            to.map { FinTSDataElement(stringLiteral: fintsDate($0)) } ?? .empty,
            .empty,
            touchdown.map { FinTSDataElement(stringLiteral: $0) } ?? .empty,
        ])
    }

    /// Transactions as camt.052 (booked + pending). `format` from `HICAZS`.
    public static func statementCAMT(
        version: Int = 1,
        account: FinTSAccount,
        format: String = "urn:iso:std:iso:20022:tech:xsd:camt.052.001.02",
        from: BankDay?,
        to: BankDay?,
        touchdown: String? = nil
    ) -> FinTSSegment {
        FinTSSegment(type: "HKCAZ", version: version, elements: [
            account.kti,
            FinTSDataElement(stringLiteral: format),
            "N",
            from.map { FinTSDataElement(stringLiteral: fintsDate($0)) } ?? .empty,
            to.map { FinTSDataElement(stringLiteral: fintsDate($0)) } ?? .empty,
            .empty,
            touchdown.map { FinTSDataElement(stringLiteral: $0) } ?? .empty,
        ])
    }

    /// Depot holdings (MT535). v6 uses KTV. No output currency by default: ING rejects one with
    /// `9210 Die Angabe einer Ausgabewährung ist nicht zulässig` (live, 2026-11-12); python-fints
    /// sends none either.
    public static func depot(version: Int, account: FinTSAccount, currency: String? = nil, touchdown: String? = nil) -> FinTSSegment {
        FinTSSegment(type: "HKWPD", version: version, elements: [
            version >= 7 ? account.kti : account.ktv,
            currency.map { FinTSDataElement(stringLiteral: $0) } ?? .empty,
            .empty,
            .empty,
            touchdown.map { FinTSDataElement(stringLiteral: $0) } ?? .empty,
        ])
    }

    public static func fintsDate(_ day: BankDay) -> String {
        String(format: "%04d%02d%02d", day.year, day.month, day.day)
    }
}
