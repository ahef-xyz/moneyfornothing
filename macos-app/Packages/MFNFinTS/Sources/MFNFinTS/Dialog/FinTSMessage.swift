import Foundation

/// Builds complete FinTS messages (HNHBK … HNHBS) for the PIN/TAN security profile.
///
/// Secured message layout:
/// ```
/// HNHBK:1:3   header (size, HBCI version 300, dialog ID, message number)
/// HNVSK:998:3 encryption head (PIN/TAN uses a dummy encryption)
/// HNVSD:999:1 encrypted data = binary of: HNSHK:2:4, business segments 3…n, HNSHA:n+1:2
/// HNHBS:n+2:1 trailer
/// ```
/// Anonymous messages (BPD retrieval) carry the business segments directly, without security.
public struct FinTSMessage {
    public struct Security {
        public var bank: FinTSBank
        public var credentials: FinTSCredentials
        public var systemID: String
        public var mechanism: FinTSTANMechanism
        public var tan: String?
    }

    public static let hbciVersion = "300"

    /// Returns the wire bytes. Segment numbers are assigned here.
    public static func build(
        dialogID: String,
        messageNumber: Int,
        segments: [FinTSSegment],
        security: Security?,
        now: Date = Date(),
        controlReference: String = Self.randomControlReference()
    ) throws(FinTSWireError) -> [UInt8] {
        var body: [UInt8] = []
        var nextNumber: Int

        if let security {
            var inner: [FinTSSegment] = []
            inner.append(signatureHead(security, controlReference: controlReference, now: now))
            var number = 3
            for var segment in segments {
                segment.number = number
                inner.append(segment)
                number += 1
            }
            inner.append(signatureTrailer(security, controlReference: controlReference, number: number))
            inner[0].number = 2
            let innerBytes = try FinTSWire.encode(inner)
            body += try FinTSWire.encode(encryptionHead(security, now: now))
            body += try FinTSWire.encode(FinTSSegment(type: "HNVSD", version: 1, number: 999, elements: [.binary(Data(innerBytes))]))
            nextNumber = number + 1
        } else {
            var number = 2
            for var segment in segments {
                segment.number = number
                body += try FinTSWire.encode([segment])
                number += 1
            }
            nextNumber = number
        }

        let trailer = try FinTSWire.encode(FinTSSegment(type: "HNHBS", version: 1, number: nextNumber, elements: [FinTSDataElement(stringLiteral: String(messageNumber))]))

        // The size field has a fixed width of 12 digits, so the header length does not depend on it.
        func header(size: Int) throws(FinTSWireError) -> [UInt8] {
            try FinTSWire.encode(FinTSSegment(type: "HNHBK", version: 3, number: 1, elements: [
                FinTSDataElement(stringLiteral: String(format: "%012d", size)),
                FinTSDataElement(stringLiteral: hbciVersion),
                FinTSDataElement(stringLiteral: dialogID),
                FinTSDataElement(stringLiteral: String(messageNumber)),
            ]))
        }
        let headerLength = try header(size: 0).count
        let total = headerLength + body.count + trailer.count
        return try header(size: total) + body + trailer
    }

    public static func randomControlReference() -> String {
        String(UInt32.random(in: 1_000_000...999_999_999))
    }

    // MARK: - Security segments

    static func encryptionHead(_ security: Security, now: Date) -> FinTSSegment {
        FinTSSegment(type: "HNVSK", version: 3, number: 998, elements: [
            FinTSDataElement(texts: ["PIN", security.mechanism.securityProfileVersion]),
            "998",
            "1",
            FinTSDataElement(texts: ["1", nil, security.systemID]),
            FinTSDataElement(texts: ["1", date(now), time(now)]),
            FinTSDataElement([.text("2"), .text("2"), .text("13"), .binary(Data(repeating: 0x30, count: 8)), .text("5"), .text("1")]),
            FinTSDataElement(texts: [security.bank.countryCode, security.bank.blz, security.credentials.userID, "V", "0", "0"]),
            "0",
        ])
    }

    static func signatureHead(_ security: Security, controlReference: String, now: Date) -> FinTSSegment {
        FinTSSegment(type: "HNSHK", version: 4, number: 2, elements: [
            FinTSDataElement(texts: ["PIN", security.mechanism.securityProfileVersion]),
            FinTSDataElement(stringLiteral: security.mechanism.securityFunction),
            FinTSDataElement(stringLiteral: controlReference),
            "1",
            "1",
            FinTSDataElement(texts: ["1", nil, security.systemID]),
            "1",
            FinTSDataElement(texts: ["1", date(now), time(now)]),
            FinTSDataElement(texts: ["1", "999", "1"]),
            FinTSDataElement(texts: ["6", "10", "16"]),
            FinTSDataElement(texts: [security.bank.countryCode, security.bank.blz, security.credentials.userID, "S", "0", "0"]),
        ])
    }

    static func signatureTrailer(_ security: Security, controlReference: String, number: Int) -> FinTSSegment {
        var auth: [String?] = [security.credentials.pin]
        if let tan = security.tan { auth.append(tan) }
        return FinTSSegment(type: "HNSHA", version: 2, number: number, elements: [
            FinTSDataElement(stringLiteral: controlReference),
            .empty,
            FinTSDataElement(texts: auth),
        ])
    }

    private static func date(_ date: Date) -> String {
        format(date, "yyyyMMdd")
    }

    private static func time(_ date: Date) -> String {
        format(date, "HHmmss")
    }

    private static func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Europe/Berlin")
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    // MARK: - Redaction

    /// Segment-level dump for debug logs with PIN, TAN, user ID and account data removed.
    /// Still log it with `privacy: .private`.
    public static func redactedDescription(_ segments: [FinTSSegment]) -> String {
        segments.map { segment in
            switch segment.type {
            case "HNSHA", "HKIDN", "HNVSK", "HNSHK", "HIUPA", "HIUPD", "HKSAL", "HKKAZ", "HKCAZ", "HKWPD", "HISAL", "HIKAZ", "HICAZ", "HIWPD":
                "\(segment.type):\(segment.number):\(segment.version)+<redacted>'"
            default:
                segment.description
            }
        }.joined()
    }
}
