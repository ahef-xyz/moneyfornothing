import Foundation
import MFNCore
@testable import MFNFinTS

/// A fake ING FinTS server answering like fints.ing.de (structure only; all data synthetic).
/// Never a real bank.
struct FakeING: Sendable {
    enum Failure: Sendable {
        case pinWrong
        case unavailable
        case rateLimited
        case garbledStatement
    }

    var failure: Failure?
    /// Giro statements are split over two pages (3040 touchdown).
    var pagedStatements = true
    /// The Extra-Konto has never received money: HKKAZ answers 9010 (segment level, HIRMG 9050).
    var emptyExtraKonto = false
    /// Same, but the 9010 comes on message level only.
    var emptyExtraKontoMessageLevel = false

    static let userID = "9876543210"
    static let pin = "Geheim-ING-4711"
    static let giroNumber = "9876543210"
    static let giroIBAN = "DE00500105179876543210"
    static let extraNumber = "5555555555"
    static let extraIBAN = "DE00500105175555555555"
    static let depotNumber = "7777777777"
    static let loanNumber = "8888888888"
    static let counterpartIBANs = ["DE00123400001234567890", "DE00999900009876543210"]

    /// 2026-11-09 12:00 Europe/Berlin.
    static let now: Date = (BankDay(year: 2026, month: 11, day: 9)?.startDate ?? .distantPast).addingTimeInterval(12 * 3600)

    static var secrets: [String] { [pin, userID, giroIBAN, extraIBAN, giroNumber, extraNumber, depotNumber] + counterpartIBANs }

    func transport() -> ScriptedFinTSTransport {
        let bank = self
        return ScriptedFinTSTransport { request, _ throws(ConnectorError) in try bank.respond(request) }
    }

    func connector(connectionID: ConnectionID = "ing-test", systemID: String = "0") -> INGConnector {
        INGConnector(connectionID: connectionID, userID: Self.userID, pin: Self.pin, transport: transport(), systemID: systemID, now: { Self.now })
    }

    // MARK: - Server

    func respond(_ request: [FinTSSegment]) throws(ConnectorError) -> [UInt8] {
        let types = request.map(\.type)
        func number(of type: String) -> Int { request.first { $0.type == type }?.number ?? 3 }
        var segments: [FinTSSegment]

        if types.contains("HKEND") {
            segments = [code("HIRMG", "0100", "Dialog beendet.")]
        } else if types.contains("HKIDN") {
            switch failure {
            case .pinWrong:
                segments = [code("HIRMG", "9050", "Die Nachricht enthält Fehler."), code("HIRMS", "9340", "Zugang gesperrt oder PIN falsch.", reference: number(of: "HKIDN"))]
            case .unavailable:
                throw .bankUnavailable
            case .rateLimited:
                throw .rateLimited(retryAfter: 120)
            default:
                segments = initResponse(request, number: number)
            }
        } else if let hksal = request.first(where: { $0.type == "HKSAL" }) {
            let account = accountNumber(hksal)
            let (amount, mark) = account == Self.giroNumber ? ("3496,80", "C") : ("12000,00", "C")
            segments = [
                code("HIRMG", "0010", "Nachricht entgegengenommen."),
                code("HIRMS", "0020", "Auftrag ausgeführt.", reference: hksal.number),
                FinTSSegment(type: "HISAL", version: hksal.version, reference: hksal.number, elements: [
                    hksal[0], "Girokonto", "EUR",
                    FinTSDataElement(texts: [mark, amount, "EUR", "20261109"]),
                    .empty,
                    FinTSDataElement(texts: ["1000,", "EUR"]),
                    FinTSDataElement(texts: [account == Self.giroNumber ? "4496,80" : "12000,", "EUR"]),
                ]),
            ]
        } else if let hkkaz = request.first(where: { $0.type == "HKKAZ" }) {
            segments = statementResponse(hkkaz)
        } else if let hkwpd = request.first(where: { $0.type == "HKWPD" }) {
            segments = [
                code("HIRMG", "0010", "Nachricht entgegengenommen."),
                code("HIRMS", "0020", "Auftrag ausgeführt.", reference: hkwpd.number),
                FinTSSegment(type: "HIWPD", version: hkwpd.version, reference: hkwpd.number, elements: [.binary(SyntheticMT940.data(SyntheticMT535.depot))]),
            ]
        } else {
            segments = [code("HIRMG", "9010", "Unbekannter Auftrag.")]
        }
        return (try? FinTSMessage.build(dialogID: "ING-DIALOG-1", messageNumber: 1, segments: segments, security: nil)) ?? []
    }

    private func initResponse(_ request: [FinTSSegment], number: (String) -> Int) -> [FinTSSegment] {
        var segments = [
            code("HIRMG", "0010", "Nachricht entgegengenommen."),
            code("HIRMS", "3050", "UPD nicht mehr aktuell, aktuelle Version enthalten.", reference: number("HKVVB")),
            code("HIRMS", "3920", "Zugelassene Zwei-Schritt-Verfahren für den Benutzer.", reference: number("HKTAN"), parameters: ["999"]),
            FinTSSegment(type: "HIBPA", version: 3, elements: ["42", FinTSDataElement(texts: ["280", INGConnector.blz]), "ING-DiBa", "3", "1", "300"]),
            FinTSSegment(type: "HISALS", version: 6, elements: ["1", "1", "0"]),
            FinTSSegment(type: "HISALS", version: 7, elements: ["1", "1", "0"]),
            FinTSSegment(type: "HIKAZS", version: 6, elements: ["1", "1", "0", FinTSDataElement(texts: ["90", "N", "N"])]),
            FinTSSegment(type: "HIKAZS", version: 7, elements: ["1", "1", "0", FinTSDataElement(texts: ["90", "N", "N"])]),
            FinTSSegment(type: "HIWPDS", version: 5, elements: ["1", "1", "0", FinTSDataElement(texts: ["N", "N", "N"])]),
            FinTSSegment(type: "HIWPDS", version: 6, elements: ["1", "1", "0", FinTSDataElement(texts: ["N", "N", "N"])]),
            FinTSSegment(type: "HIPINS", version: 1, elements: ["1", "1", "0", FinTSDataElement(texts: ["5", "10", "6", "Kontonummer", "Kunden-ID", "HKSAL", "N", "HKKAZ", "N", "HKWPD", "N"])]),
            FinTSSegment(type: "HIUPA", version: 4, elements: [FinTSDataElement(stringLiteral: Self.userID), "7", "0"]),
            upd(number: Self.giroNumber, iban: Self.giroIBAN, type: "1", product: "Girokonto", allowed: ["HKSAL", "HKKAZ"]),
            upd(number: Self.extraNumber, iban: Self.extraIBAN, type: "10", product: "Extra-Konto", allowed: ["HKSAL", "HKKAZ"]),
            upd(number: Self.depotNumber, iban: nil, type: "30", product: "Direkt-Depot", allowed: ["HKWPD"]),
            upd(number: Self.loanNumber, iban: nil, type: "40", product: "Baufinanzierung", allowed: []),
        ]
        if request.contains(where: { $0.type == "HKSYN" }) {
            segments.append(FinTSSegment(type: "HISYN", version: 4, reference: number("HKSYN"), elements: ["ING-SYS-0815"]))
        }
        return segments
    }

    private func statementResponse(_ hkkaz: FinTSSegment) -> [FinTSSegment] {
        let account = accountNumber(hkkaz)
        let ok = code("HIRMG", "0010", "Nachricht entgegengenommen.")
        if account == Self.extraNumber, emptyExtraKonto {
            return [code("HIRMG", "9050", "Die Nachricht enthält Fehler."), code("HIRMS", "9010", "Abfrage nicht möglich.", reference: hkkaz.number)]
        }
        if account == Self.extraNumber, emptyExtraKontoMessageLevel {
            return [code("HIRMG", "9010", "Abfrage nicht möglich.")]
        }
        if failure == .garbledStatement {
            return [ok, FinTSSegment(type: "HIKAZ", version: hkkaz.version, reference: hkkaz.number, elements: [.binary(Data(":20:X\r\n:61:XXXXXX\r\n-".utf8))])]
        }
        let touchdown = hkkaz[5].first
        let mt940: String
        var codes = [ok]
        if account == Self.giroNumber {
            let statements = SyntheticMT940.twoStatements.components(separatedBy: "-\n")
            if pagedStatements, touchdown == nil {
                mt940 = statements[0] + "-\n"
                codes.append(code("HIRMS", "3040", "Es liegen weitere Informationen vor.", reference: hkkaz.number, parameters: ["ING-TD-2"]))
            } else if pagedStatements {
                mt940 = statements[1]
            } else {
                mt940 = SyntheticMT940.twoStatements
            }
            codes.append(code("HIRMS", "0020", "Auftrag ausgeführt.", reference: hkkaz.number))
        } else {
            mt940 = """
            :20:STARTUMSE
            :25:50010517/0000000000
            :28C:00000/001
            :60F:C260930EUR11990,00
            :61:2609300930CR10,00NMSCNONREF
            :86:805?00Zinsen?20Zinsen 3. Quartal
            :61:2610011001CR0,00NMSCNONREF
            :86:808?00Abschluss?20Rechnungsabschluss
            :62F:C261001EUR12000,00
            -
            """
        }
        return codes + [FinTSSegment(type: "HIKAZ", version: hkkaz.version, reference: hkkaz.number, elements: [.binary(SyntheticMT940.data(mt940))])]
    }

    private func accountNumber(_ segment: FinTSSegment) -> String? {
        let reference = segment[0]
        return reference.components.count >= 6 ? reference[2] : reference[0]
    }

    private func upd(number: String, iban: String?, type: String, product: String, allowed: [String]) -> FinTSSegment {
        var elements: [FinTSDataElement] = [
            FinTSDataElement(texts: [number, nil, "280", INGConnector.blz]),
            iban.map { FinTSDataElement(stringLiteral: $0) } ?? .empty,
            FinTSDataElement(stringLiteral: Self.userID),
            FinTSDataElement(stringLiteral: type),
            "EUR", "Muster", "Erika",
            FinTSDataElement(stringLiteral: product),
            .empty,
        ]
        elements += allowed.map { FinTSDataElement(texts: [$0, "1"]) }
        return FinTSSegment(type: "HIUPD", version: 6, elements: elements)
    }

    private func code(_ type: String, _ code: String, _ text: String, reference: Int? = nil, parameters: [String] = []) -> FinTSSegment {
        var texts: [String?] = [code, nil, text]
        texts += parameters.map { Optional($0) }
        return FinTSSegment(type: type, version: 2, reference: reference, elements: [FinTSDataElement(texts: texts)])
    }
}
