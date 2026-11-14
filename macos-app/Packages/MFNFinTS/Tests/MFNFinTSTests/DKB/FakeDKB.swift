import Foundation
import MFNCore
import Synchronization
@testable import MFNFinTS

/// Synthetic DKB FinTS server for tests. Never a real bank; all data invented
/// (IBANs `DE00…`, names are placeholders). Mirrors the documented DKB behaviour:
/// HITANS v6/v7 with method 942, decoupled approval (`HITAN` + `3956`, poll with `HKTAN` S),
/// credit card as its own UPD account, camt.052 via HKCAZ with 3040 paging.
final class FakeDKB: Sendable {
    enum Phase: Sendable { case current, afterBooking }

    struct Options: Sendable {
        var phase: Phase = .current
        /// The bank demands approval on dialog init (first login, every 90 days).
        var initSCA = false
        /// The bank demands approval for the statement request (history > 90 days).
        var statementSCA = false
        /// Number of polls answered with `3956` before the approval goes through.
        var pollsUntilApproval = 1
        /// Poll answer after the user rejected in the app.
        var rejectApproval = false
        var pinWrong = false
        var brokenCAMT = false
        var transportError: ConnectorError?
        /// No camt: BPD without `HICAZS`, UPD without `HKCAZ` → the connector falls back to HKKAZ (MT940/MT942).
        var mt940Only = false
    }

    static let pin = "dkb-pin-0815"
    static let login = "dkbtestuser"
    static let giroIBAN = "DE00120300001234567890"
    static let savingsIBAN = "DE00120300001234567891"
    static let cardNumber = "4930000000004711"
    static let systemID = "DKB-SYS-0001"
    static let credentials = FinTSCredentials(userID: login, pin: pin)
    static let secrets = [pin, login, giroIBAN, savingsIBAN, cardNumber, "1234567890", "1234567891"]

    enum Order: Sendable {
        case dialogInit([FinTSSegment])
        case statement([FinTSSegment])
    }

    struct State: Sendable {
        var polls = 0
        var pendingOrder: Order?
        var initApproved = false
        var statementApproved = false
    }

    let options: Options
    let state = Mutex(State())

    init(_ options: Options = Options()) {
        self.options = options
    }

    func transport() -> ScriptedFinTSTransport {
        ScriptedFinTSTransport { request, _ throws(ConnectorError) in
            if let error = self.options.transportError { throw error }
            return self.respond(request)
        }
    }

    // MARK: - Dispatch

    func respond(_ request: [FinTSSegment]) -> [UInt8] {
        let types = request.map(\.type)
        func number(_ type: String) -> Int { request.first { $0.type == type }?.number ?? 3 }
        var segments: [FinTSSegment]

        if types.contains("HKEND") {
            segments = [code("HIRMG", "0100", "Dialog beendet.")]
        } else if let hkidn = request.first(where: { $0.type == "HKIDN" }) {
            if hkidn[1].first == "9999999999" {
                segments = [code("HIRMG", "0010", "Nachricht entgegengenommen.")] + bpd
            } else {
                segments = personalInit(request, number: number)
            }
        } else if let hktan = request.first(where: { $0.type == "HKTAN" }), hktan[0].first == "S" {
            segments = poll(hktan, number: number("HKTAN"))
        } else if let hksal = request.first(where: { $0.type == "HKSAL" }) {
            segments = [code("HIRMG", "0010", "OK"), code("HIRMS", "0020", "Auftrag ausgeführt.", reference: number("HKSAL"))]
            segments.append(contentsOf: balance(accountNumber: hksal[0][2], reference: number("HKSAL")))
        } else if let hkkaz = request.first(where: { $0.type == "HKKAZ" }) {
            segments = [code("HIRMG", "0010", "OK"), code("HIRMS", "0020", "Auftrag ausgeführt.", reference: number("HKKAZ"))]
            let (booked, pending) = Self.mt940(accountNumber: hkkaz[0][2] ?? "", phase: options.phase)
            var elements: [FinTSDataElement] = [.binary(Data(booked.utf8))]
            if let pending { elements.append(.binary(Data(pending.utf8))) }
            segments.append(FinTSSegment(type: "HIKAZ", version: 7, reference: number("HKKAZ"), elements: elements))
        } else if let hkcaz = request.first(where: { $0.type == "HKCAZ" }) {
            segments = statement(hkcaz, request: request, number: number)
        } else if request.contains(where: { $0.type == "HKWPD" }) {
            segments = [
                code("HIRMG", "0010", "OK"), code("HIRMS", "0020", "Auftrag ausgeführt.", reference: number("HKWPD")),
                FinTSSegment(type: "HIWPD", version: 6, reference: number("HKWPD"), elements: [.binary(Data(Self.mt535.utf8))]),
            ]
        } else {
            segments = [code("HIRMG", "9010", "Unbekannter Auftrag.")]
        }
        return (try? FinTSMessage.build(dialogID: "DKB-DIALOG-1", messageNumber: 1, segments: segments, security: nil)) ?? []
    }

    private func personalInit(_ request: [FinTSSegment], number: (String) -> Int) -> [FinTSSegment] {
        if options.pinWrong {
            return [code("HIRMG", "9050", "Teilweise fehlerhaft."), code("HIRMS", "9340", "PIN falsch.", reference: number("HKIDN"))]
        }
        var data = bpd + upd
        if request.contains(where: { $0.type == "HKSYN" }) {
            data.append(FinTSSegment(type: "HISYN", version: 4, reference: number("HKSYN"), elements: [FinTSDataElement(stringLiteral: Self.systemID)]))
        }
        let needsSCA = options.initSCA && !state.withLock { $0.initApproved }
        if needsSCA {
            state.withLock { $0.pendingOrder = .dialogInit([]); $0.polls = 0 }
            return [
                code("HIRMG", "3060", "Bitte beachten Sie die enthaltenen Warnungen/Hinweise."),
                code("HIRMS", "3956", "Starke Kundenauthentifizierung noch ausstehend.", reference: number("HKTAN")),
                FinTSSegment(type: "HITAN", version: 7, reference: number("HKTAN"), elements: ["4", .empty, "INIT-REF-1", "Bitte bestätige die Anmeldung in der DKB-App."]),
            ] + data
        }
        return [
            code("HIRMG", "0010", "Nachricht entgegengenommen."),
            code("HIRMS", "3076", "Starke Kundenauthentifizierung nicht notwendig.", reference: number("HKTAN")),
        ] + data
    }

    private func poll(_ hktan: FinTSSegment, number: Int) -> [FinTSSegment] {
        let (polls, order) = state.withLock { state -> (Int, Order?) in
            state.polls += 1
            return (state.polls, state.pendingOrder)
        }
        guard let order else { return [code("HIRMG", "9800", "Kein offener Auftrag.")] }
        if options.rejectApproval {
            return [code("HIRMG", "3060", "Warnungen."), code("HIRMS", "9941", "Freigabe abgelehnt.", reference: number)]
        }
        if polls < options.pollsUntilApproval {
            return [code("HIRMG", "0010", "OK"), code("HIRMS", "3956", "Starke Kundenauthentifizierung noch ausstehend.", reference: number)]
        }
        state.withLock { state in
            state.pendingOrder = nil
            switch order {
            case .dialogInit: state.initApproved = true
            case .statement: state.statementApproved = true
            }
        }
        switch order {
        case .dialogInit:
            return [code("HIRMG", "0010", "OK"), code("HIRMS", "0020", "Freigabe erteilt.", reference: number)]
        case let .statement(result):
            return [code("HIRMG", "0010", "OK"), code("HIRMS", "0020", "Auftrag ausgeführt.", reference: number)] + result.map { segment in
                var segment = segment
                segment.reference = number
                return segment
            }
        }
    }

    private func statement(_ hkcaz: FinTSSegment, request: [FinTSSegment], number: (String) -> Int) -> [FinTSSegment] {
        let accountNumber = hkcaz[0][2] ?? ""
        let touchdown = hkcaz[6].first
        let reference = number("HKCAZ")
        let pages = Self.camtPages(accountNumber: accountNumber, phase: options.phase, broken: options.brokenCAMT)
        let page = touchdown.flatMap { Int($0.dropFirst()) } ?? 1
        var result: [FinTSSegment] = []
        if page < pages.count {
            result.append(code("HIRMS", "3040", "Es liegen weitere Informationen vor.", reference: reference, parameters: ["P\(page + 1)"]))
        }
        if pages.indices.contains(page - 1) {
            let (booked, pending) = pages[page - 1]
            var elements: [FinTSDataElement] = [
                FinTSDataElement(texts: [nil, nil, accountNumber, nil, "280", "12030000"]),
                "urn:iso:std:iso:20022:tech:xsd:camt.052.001.08",
                FinTSDataElement(booked.map { .binary($0) }),
            ]
            if let pending { elements.append(.binary(pending)) }
            result.append(FinTSSegment(type: "HICAZ", version: 1, reference: reference, elements: elements))
        } else {
            result.append(code("HIRMS", "3010", "Keine Umsätze vorhanden.", reference: reference))
        }

        let needsSCA = options.statementSCA && page == 1 && !state.withLock { $0.statementApproved }
        if needsSCA {
            state.withLock { $0.pendingOrder = .statement(result); $0.polls = 0 }
            return [
                code("HIRMG", "3060", "Warnungen."),
                code("HIRMS", "3956", "Starke Kundenauthentifizierung noch ausstehend.", reference: number("HKTAN")),
                FinTSSegment(type: "HITAN", version: 7, reference: number("HKTAN"), elements: ["4", .empty, "CAZ-REF-1", "Bitte bestätige den Umsatzabruf in der DKB-App."]),
            ]
        }
        return [code("HIRMG", "0010", "OK"), code("HIRMS", "0020", "Auftrag ausgeführt.", reference: reference)] + result
    }

    private func balance(accountNumber: String?, reference: Int) -> [FinTSSegment] {
        let (sign, amount, available): (String, String, String?) = switch accountNumber {
        case "1234567890": ("C", "1234,56", "3734,56")
        case "1234567891": ("C", "10000,", nil)
        case Self.cardNumber: ("D", "123,45", "2376,55")
        default: ("C", "0,", nil)
        }
        var elements: [FinTSDataElement] = [
            FinTSDataElement(texts: [nil, nil, accountNumber, nil, "280", "12030000"]), "Konto", "EUR",
            FinTSDataElement(texts: [sign, amount, "EUR", "20261109"]), .empty, .empty,
        ]
        if let available { elements.append(FinTSDataElement(texts: [available, "EUR"])) }
        return [FinTSSegment(type: "HISAL", version: 7, reference: reference, elements: elements)]
    }

    // MARK: - Parameter data

    static func tanMethod(_ function: String, name: String, version: Int, polls: [String?]) -> [String?] {
        var fields: [String?] = [function, "2", name, nil, nil, name, nil, nil, nil, nil, "N", "1", "N", "0", "0", "0", "N", "00", "0", "N", "1"]
        if version >= 7 { fields += polls + ["J", "J"] }
        return fields
    }

    var bpd: [FinTSSegment] {
        options.mt940Only ? Self.bpd.filter { $0.type != "HICAZS" } : Self.bpd
    }

    var upd: [FinTSSegment] {
        options.mt940Only ? Self.upd(camt: false) : Self.upd
    }

    static let bpd: [FinTSSegment] = [
        FinTSSegment(type: "HIBPA", version: 3, elements: ["42", FinTSDataElement(texts: ["280", "12030000"]), "DKB", "3", "1", "300"]),
        FinTSSegment(type: "HITANS", version: 6, elements: ["1", "1", "0", FinTSDataElement(texts: ["J", "N", "0"] + tanMethod("942", name: "DKB-App", version: 6, polls: []))]),
        FinTSSegment(type: "HITANS", version: 7, elements: ["1", "1", "0", FinTSDataElement(texts: ["J", "N", "0"]
            + tanMethod("942", name: "DKB-App", version: 7, polls: ["10", "3", "1"])
            + tanMethod("912", name: "chipTAN", version: 7, polls: [nil, nil, nil]))]),
        FinTSSegment(type: "HIPINS", version: 1, elements: ["1", "1", "0", FinTSDataElement(texts: [
            "5", "20", "6", "Anmeldename", "Kunden-ID", "HKSAL", "J", "HKCAZ", "J", "HKKAZ", "J", "HKWPD", "J", "HKSPA", "N", "HKTAN", "N",
        ])]),
        FinTSSegment(type: "HISALS", version: 7, elements: ["1", "1", "0"]),
        FinTSSegment(type: "HIKAZS", version: 7, elements: ["1", "1", "0", FinTSDataElement(texts: ["450", "N", "N"])]),
        FinTSSegment(type: "HICAZS", version: 1, elements: ["1", "1", "0", FinTSDataElement(texts: [
            "450", "N", "urn:iso:std:iso:20022:tech:xsd:camt.052.001.02", "urn:iso:std:iso:20022:tech:xsd:camt.052.001.08",
        ])]),
        FinTSSegment(type: "HIWPDS", version: 6, elements: ["1", "1", "0", FinTSDataElement(texts: ["N"])]),
    ]

    static let upd = upd(camt: true)

    static func upd(camt: Bool) -> [FinTSSegment] {
        let statement = camt ? ["HKCAZ"] : ["HKKAZ"]
        return [
        FinTSSegment(type: "HIUPA", version: 4, elements: [FinTSDataElement(stringLiteral: login), "7", "0"]),
        hiupd("1234567890", iban: giroIBAN, type: "1", product: "Girokonto", limit: FinTSDataElement(texts: ["E", "2500,", "EUR"]), allowed: ["HKSAL", "HKKAZ", "HKSPA"] + (camt ? ["HKCAZ"] : [])),
        hiupd("1234567891", iban: savingsIBAN, type: "10", product: "Tagesgeld", limit: .empty, allowed: ["HKSAL"] + statement),
        hiupd("501234567", iban: nil, type: "30", product: "Depot", limit: .empty, allowed: ["HKWPD"]),
        hiupd(cardNumber, iban: nil, type: "50", product: "DKB Visa Kreditkarte", limit: FinTSDataElement(texts: ["E", "2500,", "EUR"]), allowed: ["HKSAL"] + statement),
        hiupd("9988776655", iban: nil, type: "40", product: "Privatdarlehen", limit: .empty, allowed: ["HKSAL"]),
        ]
    }

    static func hiupd(_ number: String, iban: String?, type: String, product: String, limit: FinTSDataElement, allowed: [String]) -> FinTSSegment {
        FinTSSegment(type: "HIUPD", version: 6, elements: [
            FinTSDataElement(texts: [number, nil, "280", "12030000"]),
            iban.map { FinTSDataElement(stringLiteral: $0) } ?? .empty,
            FinTSDataElement(stringLiteral: login), FinTSDataElement(stringLiteral: type), "EUR",
            "Muster", "Erika", FinTSDataElement(stringLiteral: product), limit,
        ] + allowed.map { FinTSDataElement(texts: [$0, "1"]) })
    }

    // MARK: - camt.052 content

    /// Pages per account: (booked documents, pending document).
    static func camtPages(accountNumber: String, phase: Phase, broken: Bool) -> [([Data], Data?)] {
        if broken { return [([Data("<Document><BkToCstmrAcctRpt><Rpt><Ntry><Amt>".utf8)], nil)] }
        switch accountNumber {
        case "1234567890":
            let page1: [CAMTEntry] = [
                CAMTEntry(amount: "2500.00", debit: false, booking: "2026-10-30", name: "Arbeitgeber GmbH", iban: "DE00500105170000000001", purpose: ["LOHN/GEHALT 10/2026"], eref: "NOTPROVIDED"),
                CAMTEntry(amount: "45.90", debit: true, booking: "2026-11-02", name: "Stadtwerke Muster", iban: "DE00700500000000000002", purpose: ["Abschlag Strom", "Kd-Nr. 4711"], eref: "E2E-STROM-11", mref: "MANDAT-001", creditorID: "DE98ZZZ09999999999"),
                CAMTEntry(amount: "4.20", debit: true, booking: "2026-11-03", name: "Baeckerei Korn", purpose: ["Kartenzahlung"]),
                CAMTEntry(amount: "4.20", debit: true, booking: "2026-11-03", name: "Baeckerei Korn", purpose: ["Kartenzahlung"]),
            ]
            let page2: [CAMTEntry] = [
                CAMTEntry(amount: "800.00", debit: true, booking: "2026-11-05", name: "Vermieterin Muster", iban: "DE00100100100000000003", purpose: ["Miete November"]),
            ]
            let pending = CAMTEntry(amount: "23.45", debit: true, status: "PDNG", booking: nil, value: "2026-11-08", name: "REWE Markt", purpose: ["Kartenzahlung girocard"])
            let booked = CAMTEntry(amount: "23.45", debit: true, booking: "2026-11-09", value: "2026-11-08", name: "REWE MARKT GMBH SAGT DANKE", purpose: ["Kartenzahlung girocard 2026-11-08"])
            switch phase {
            case .current: return [([camt(page1)], camt([pending])), ([camt(page2)], nil)]
            case .afterBooking: return [([camt(page1)], nil), ([camt(page2 + [booked])], nil)]
            }
        case "1234567891":
            return [([camt([CAMTEntry(amount: "12.34", debit: false, booking: "2026-10-31", name: "DKB AG", purpose: ["Zinsen"])])], nil)]
        case cardNumber:
            let base = [
                CAMTEntry(amount: "11.20", debit: true, booking: "2026-11-01", name: "UBER TRIP", purpose: ["UBER *TRIP HELP.UBER.COM"], instructed: ("12.00", "USD")),
                CAMTEntry(amount: "9.99", debit: true, booking: "2026-11-04", name: "Streamingdienst", purpose: ["Abo November"]),
            ]
            let pending = CAMTEntry(amount: "59.99", debit: true, status: "PDNG", booking: nil, value: "2026-11-07", name: "AMAZON", purpose: ["AMAZON MKTPLACE"])
            let booked = CAMTEntry(amount: "59.99", debit: true, booking: "2026-11-09", value: "2026-11-07", name: "AMAZON EU SARL", purpose: ["AMAZON MKTPLACE 2026-11-07"])
            switch phase {
            case .current: return [([camt(base)], camt([pending]))]
            case .afterBooking: return [([camt(base + [booked])], nil)]
            }
        default:
            return []
        }
    }

    // MARK: - SWIFT content (MT940/MT942/MT535)

    /// Depot holdings: 10 Muster AG at 85,50 EUR, 12,5 ETF units at 98,765 EUR, one bond without ISIN (skipped).
    static let mt535 = """
    :16R:GENL
    :28E:1/ONLY
    :20C::SEME//NONREF
    :23G:NEWM
    :98A::STAT//20261109
    :97A::SAFE//12030000/501234567
    :16S:GENL
    :16R:FIN
    :35B:ISIN DE0005190003/DE/519000
    MUSTER AG
    :90B::MRKT//ACTU/EUR85,50
    :98A::PRIC//20261106
    :93B::AGGR//UNIT/10,
    :19A::HOLD//EUR855,
    :16S:FIN
    :16R:FIN
    :35B:ISIN IE00B4L5Y983/DE/A0RPWH
    WELT ETF
    :90B::MRKT//ACTU/EUR98,765
    :98A::PRIC//20261106
    :93B::AGGR//UNIT/12,5
    :16S:FIN
    :16R:FIN
    :35B:/DE/999999
    OHNE ISIN
    :93B::AGGR//UNIT/1,
    :16S:FIN
    """

    /// HIKAZ for the MT940 fallback: booked (MT940) and pending (MT942) per account.
    static func mt940(accountNumber: String, phase: Phase) -> (booked: String, pending: String?) {
        guard accountNumber == "1234567890" else {
            return ("""
            :20:STARTUMSE
            :25:12030000/\(accountNumber)
            :28C:00000/001
            :60F:C261029EUR0,00
            :61:2610311031CR12,34NMSCNONREF
            :86:805?00Zinsen?20SVWZ+Zinsen?32DKB AG
            :62F:C261031EUR12,34
            -
            """, nil)
        }
        let rewe = """
        :61:2611081109DR23,45NMSCNONREF
        :86:106?00Kartenzahlung?20SVWZ+Kartenzahlung girocard?32REWE MARKT GMBH SAGT DANKE

        """
        let booked = """
        :20:STARTUMSE
        :25:12030000/1234567890
        :28C:00000/001
        :60F:C261029EUR1000,00
        :61:2610301030CR2500,00NMSCNONREF
        :86:166?00Gutschrift?20SVWZ+LOHN/GEHALT 10/2026?31DE00500105170000000001?32Arbeitgeber GmbH
        :61:2611021102DR45,90NDDTNONREF
        :86:105?00Lastschrift?20EREF+E2E-STROM-11 MREF+MANDAT-001?21CRED+DE98ZZZ09999999999?22SVWZ+Abschlag Strom?31DE00700500000000000002?32Stadtwerke Muster
        :61:2611051105DR800,00NMSCNONREF
        :86:177?00Ueberweisung?20SVWZ+Miete November?31DE00100100100000000003?32Vermieterin Muster
        \(phase == .afterBooking ? rewe : ""):62F:C261109EUR2654,10
        -
        """
        let pending = """
        :20:STARTDISPE
        :25:12030000/1234567890
        :28C:00000/001
        :34F:EURD0,
        :13D:2611091200+0100
        :61:2611081108DR23,45NMSCNONREF
        :86:106?00Kartenzahlung?20SVWZ+Kartenzahlung girocard?32REWE Markt
        :90D:1EUR23,45
        :90C:0EUR0,
        -
        """
        return (booked, phase == .current ? pending : nil)
    }

    // MARK: - Helpers

    func code(_ type: String, _ code: String, _ text: String, reference: Int? = nil, parameters: [String] = []) -> FinTSSegment {
        Self.code(type, code, text, reference: reference, parameters: parameters)
    }

    static func code(_ type: String, _ code: String, _ text: String, reference: Int? = nil, parameters: [String] = []) -> FinTSSegment {
        var texts: [String?] = [code, nil, text]
        texts += parameters.map { Optional($0) }
        return FinTSSegment(type: type, version: 2, reference: reference, elements: [FinTSDataElement(texts: texts)])
    }
}

/// One synthetic camt.052 entry.
struct CAMTEntry {
    var amount: String
    var currency = "EUR"
    var debit: Bool
    var status = "BOOK"
    var booking: String?
    var value: String?
    var name: String?
    var iban: String?
    var purpose: [String] = []
    var eref: String?
    var mref: String?
    var creditorID: String?
    var instructed: (amount: String, currency: String)?
}

/// Builds a camt.052 document. `v08` uses `<Sts><Cd>` and `<Pty>`-wrapped parties.
func camt(_ entries: [CAMTEntry], v08: Bool = true, iban: String = "DE00120300001234567890") -> Data {
    func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
    }
    let namespace = v08 ? "urn:iso:std:iso:20022:tech:xsd:camt.052.001.08" : "urn:iso:std:iso:20022:tech:xsd:camt.052.001.02"
    var xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <Document xmlns="\(namespace)"><BkToCstmrAcctRpt><GrpHdr><MsgId>MSG1</MsgId><CreDtTm>2026-11-09T08:00:00</CreDtTm></GrpHdr>
    <Rpt><Id>R1</Id><Acct><Id><IBAN>\(iban)</IBAN></Id></Acct>
    """
    for entry in entries {
        let party = entry.debit ? "Cdtr" : "Dbtr"
        var parties = ""
        if let name = entry.name {
            let nameXML = "<Nm>\(escape(name))</Nm>"
            let idXML = entry.creditorID.map { "<Id><PrvtId><Othr><Id>\($0)</Id><SchmeNm><Prtry>SEPA</Prtry></SchmeNm></Othr></PrvtId></Id>" } ?? ""
            parties += v08 ? "<\(party)><Pty>\(nameXML)\(idXML)</Pty></\(party)>" : "<\(party)>\(nameXML)\(idXML)</\(party)>"
        }
        if let iban = entry.iban { parties += "<\(party)Acct><Id><IBAN>\(iban)</IBAN></Id></\(party)Acct>" }
        let status = v08 ? "<Sts><Cd>\(entry.status)</Cd></Sts>" : "<Sts>\(entry.status)</Sts>"
        var refs = ""
        if let eref = entry.eref { refs += "<EndToEndId>\(eref)</EndToEndId>" }
        if let mref = entry.mref { refs += "<MndtId>\(mref)</MndtId>" }
        let amountDetails = entry.instructed.map { "<AmtDtls><InstdAmt><Amt Ccy=\"\($0.currency)\">\($0.amount)</Amt></InstdAmt></AmtDtls>" } ?? ""
        xml += """
        <Ntry><Amt Ccy="\(entry.currency)">\(entry.amount)</Amt><CdtDbtInd>\(entry.debit ? "DBIT" : "CRDT")</CdtDbtInd>\(status)
        \(entry.booking.map { "<BookgDt><Dt>\($0)</Dt></BookgDt>" } ?? "")\((entry.value ?? entry.booking).map { "<ValDt><Dt>\($0)</Dt></ValDt>" } ?? "")
        <NtryDtls><TxDtls>\(refs.isEmpty ? "" : "<Refs>\(refs)</Refs>")\(amountDetails)<RltdPties>\(parties)</RltdPties>
        <RmtInf>\(entry.purpose.map { "<Ustrd>\(escape($0))</Ustrd>" }.joined())</RmtInf></TxDtls></NtryDtls></Ntry>
        """
    }
    xml += "</Rpt></BkToCstmrAcctRpt></Document>"
    return Data(xml.utf8)
}

// MARK: - Test doubles

/// Returns immediately; records every requested wait.
final class TestClock: DecoupledClock {
    let sleeps = Mutex<[Duration]>([])

    func sleep(for duration: Duration) async throws(ConnectorError) {
        sleeps.withLock { $0.append(duration) }
        for _ in 0..<5 { await Task.yield() }
        if Task.isCancelled { throw .cancelled }
    }

    var recorded: [Duration] { sleeps.withLock { $0 } }
}

/// Shows the sheet until the connector cancels it (approval detected by polling).
final class WaitingPresenter: AuthChallengePresenter {
    let challenges = Mutex<[AuthChallenge]>([])

    func present(_ challenge: AuthChallenge) async throws -> AuthResponse {
        challenges.withLock { $0.append(challenge) }
        try await Task.sleep(for: .seconds(3600))
        return .confirmed
    }

    var presented: [AuthChallenge] { challenges.withLock { $0 } }
}

/// The user taps "Ich habe freigegeben" right away.
struct ConfirmingPresenter: AuthChallengePresenter {
    func present(_ challenge: AuthChallenge) async throws -> AuthResponse { .confirmed }
}

/// The user cancels the sheet.
struct CancellingPresenter: AuthChallengePresenter {
    func present(_ challenge: AuthChallenge) async throws -> AuthResponse { throw ConnectorError.cancelled }
}

let fakeToday = BankDay(year: 2026, month: 11, day: 9)?.startDate.addingTimeInterval(12 * 3600) ?? Date()

func makeDKBConnector(
    _ bank: FakeDKB,
    presenter: (any AuthChallengePresenter)? = WaitingPresenter(),
    store: any DKBStateStore = InMemoryDKBStateStore(),
    clock: TestClock = TestClock(),
    transport: ScriptedFinTSTransport? = nil,
    parsers: DKBStatementParsers = .standard
) -> DKBConnector {
    DKBConnector(
        connectionID: "dkb-test",
        credentials: FakeDKB.credentials,
        presenter: presenter,
        transport: transport ?? bank.transport(),
        stateStore: store,
        clock: clock,
        parsers: parsers,
        now: { fakeToday }
    )
}
