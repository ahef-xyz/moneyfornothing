import Foundation
import MFNCore

/// Parses camt.052 account reports (`HICAZ`) into `Transaction`s.
///
/// Supports camt.052.001.02 … .08 (status as `<Sts>BOOK</Sts>` or `<Sts><Cd>BOOK</Cd></Sts>`,
/// related parties with or without `<Pty>`). Namespaces are ignored; only local names count.
///
/// Mapping per `Ntry`:
/// - `Amt` + `CdtDbtInd` → signed `amountCents` (`DBIT` negative), currency from `Amt@Ccy`.
/// - `Sts` `BOOK` → booked, `PDNG` → pending, `INFO` → planned; missing → `defaultStatus`.
/// - `BookgDt` → `bookingDate` (booked only), `ValDt` → `valueDate`.
/// - `RmtInf/Ustrd` → purpose; counterparty is the creditor for debits, the debtor for credits.
/// - `Refs/EndToEndId`, `Refs/MndtId`, creditor ID (`Cdtr/Id/PrvtId/Othr/Id`) → eref, mref, creditorID.
/// - `AmtDtls/InstdAmt` in another currency → `originalAmountCents`/`originalCurrency`.
/// - The whole `Ntry` subtree as JSON → `rawJSON`.
///
/// No interpretation beyond that (no categories, no merchant cleanup): that is `MFNCore`'s job.
public enum CAMTParser {
    /// Parses one camt.052 document. `defaultStatus` applies to entries without `Sts`
    /// (HICAZ element 3 carries the not yet booked entries).
    public static func parse(_ data: Data, accountID: AccountID, defaultStatus: TransactionStatus = .booked) throws(ConnectorError) -> [Transaction] {
        let root = try CAMTNode.parse(data)
        guard root.name == "BkToCstmrAcctRpt" || root.descendant("BkToCstmrAcctRpt") != nil else {
            throw .formatChanged(detail: "camt.052: kein BkToCstmrAcctRpt")
        }
        let reportDay = root.descendant("GrpHdr")?.child("CreDtTm").flatMap { day($0.text) }
        var result: [Transaction] = []
        for report in root.descendants("Rpt") {
            for entry in report.children("Ntry") {
                result.append(try transaction(entry, accountID: accountID, defaultStatus: defaultStatus, reportDay: reportDay))
            }
        }
        return result
    }

    static func transaction(_ entry: CAMTNode, accountID: AccountID, defaultStatus: TransactionStatus, reportDay: BankDay?) throws(ConnectorError) -> Transaction {
        guard let amountNode = entry.child("Amt"), let magnitude = cents(amountNode.text) else {
            throw .formatChanged(detail: "camt.052: Ntry ohne lesbaren Betrag")
        }
        let currency = amountNode.attributes["Ccy"] ?? "EUR"
        let isDebit: Bool
        switch entry.child("CdtDbtInd")?.text {
        case "DBIT": isDebit = true
        case "CRDT": isDebit = false
        default: throw .formatChanged(detail: "camt.052: CdtDbtInd fehlt")
        }
        let amount = isDebit ? -magnitude : magnitude

        let status = status(entry.child("Sts")) ?? defaultStatus
        let booking = entry.child("BookgDt").flatMap(date)
        let value = entry.child("ValDt").flatMap(date)
        guard let valueDate = value ?? booking ?? reportDay else {
            throw .formatChanged(detail: "camt.052: Ntry ohne Datum")
        }
        let bookingDate: BankDay? = status == .booked ? (booking ?? valueDate) : nil

        let details = entry.child("NtryDtls")?.children("TxDtls") ?? []
        let tx = details.first
        let parties = tx?.child("RltdPties")
        let counterpart = isDebit ? "Cdtr" : "Dbtr"
        let ultimate = isDebit ? "UltmtCdtr" : "UltmtDbtr"

        let name = partyName(parties?.child(counterpart)) ?? partyName(parties?.child(ultimate))
        let iban = parties?.child(counterpart + "Acct")?.path("Id", "IBAN")?.text.nonEmpty

        let unstructured = details.flatMap { $0.child("RmtInf")?.children("Ustrd") ?? [] }.compactMap(\.text.trimmed.nonEmpty)
        let additional = (tx?.child("AddtlTxInf")?.text ?? entry.child("AddtlNtryInf")?.text)?.trimmed.nonEmpty
        let purpose = unstructured.isEmpty ? (additional ?? "") : unstructured.joined(separator: " ")

        let refs = tx?.child("Refs")
        let eref = refs?.child("EndToEndId")?.text.trimmed.nonEmpty.flatMap { $0 == "NOTPROVIDED" ? nil : $0 }
        let mref = refs?.child("MndtId")?.text.trimmed.nonEmpty
        let creditorParty = parties?.child("Cdtr").map { $0.child("Pty") ?? $0 }
        let creditorID = creditorParty?.path("Id", "PrvtId", "Othr", "Id")?.text.trimmed.nonEmpty

        var originalAmount: Int?
        var originalCurrency: String?
        if let instructed = tx?.path("AmtDtls", "InstdAmt", "Amt"),
           let ccy = instructed.attributes["Ccy"], ccy != currency, let value = cents(instructed.text) {
            originalAmount = isDebit ? -value : value
            originalCurrency = ccy
        }

        return Transaction(
            accountID: accountID,
            bookingDate: bookingDate,
            valueDate: valueDate,
            amountCents: amount,
            currency: currency,
            counterpartName: (name ?? additional ?? "").trimmed,
            counterpartIBAN: iban.map { Fingerprint.normalize(iban: $0) },
            purpose: purpose,
            eref: eref,
            mref: mref,
            creditorID: creditorID,
            status: status,
            originalAmountCents: originalAmount,
            originalCurrency: originalCurrency,
            rawJSON: entry.jsonData()
        )
    }

    // MARK: - Field helpers

    static func status(_ node: CAMTNode?) -> TransactionStatus? {
        guard let node else { return nil }
        let code = (node.child("Cd")?.text ?? node.text).trimmed.uppercased()
        switch code {
        case "BOOK": return .booked
        case "PDNG": return .pending
        case "INFO", "FUTR": return .planned
        default: return nil
        }
    }

    static func partyName(_ node: CAMTNode?) -> String? {
        guard let node else { return nil }
        return (node.child("Nm") ?? node.path("Pty", "Nm"))?.text.trimmed.nonEmpty
    }

    static func date(_ node: CAMTNode) -> BankDay? {
        day((node.child("Dt") ?? node.child("DtTm"))?.text ?? node.text)
    }

    static func day(_ text: String) -> BankDay? {
        let trimmed = text.trimmed
        guard trimmed.count >= 10 else { return nil }
        return BankDay(iso: String(trimmed.prefix(10)))
    }

    /// `"1234.5"` → 123450. Exact decimal parsing, never `Double`.
    static func cents(_ text: String) -> Int? {
        let trimmed = text.trimmed
        guard !trimmed.isEmpty, !trimmed.hasPrefix("-") else { return nil }
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, let whole = Int(parts[0].isEmpty ? "0" : parts[0]) else { return nil }
        var fraction = parts.count == 2 ? String(parts[1]) : ""
        guard fraction.count <= 2, fraction.allSatisfy(\.isNumber) else { return nil }
        while fraction.count < 2 { fraction += "0" }
        guard let decimals = Int(fraction) else { return nil }
        let (product, overflow) = whole.multipliedReportingOverflow(by: 100)
        guard !overflow else { return nil }
        return product + decimals
    }
}

// MARK: - Minimal XML tree

/// A small element tree over `XMLParser` (Foundation). Local names only, text trimmed later.
struct CAMTNode: Sendable {
    var name: String
    var attributes: [String: String]
    var children: [CAMTNode]
    var text: String

    func child(_ name: String) -> CAMTNode? { children.first { $0.name == name } }
    func children(_ name: String) -> [CAMTNode] { children.filter { $0.name == name } }

    func path(_ names: String...) -> CAMTNode? {
        var node: CAMTNode? = self
        for name in names { node = node?.child(name) }
        return node
    }

    func descendant(_ name: String) -> CAMTNode? {
        for child in children {
            if child.name == name { return child }
            if let found = child.descendant(name) { return found }
        }
        return nil
    }

    func descendants(_ name: String) -> [CAMTNode] {
        children.flatMap { $0.name == name ? [$0] : $0.descendants(name) }
    }

    static func parse(_ data: Data) throws(ConnectorError) -> CAMTNode {
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = builder
        guard parser.parse(), let root = builder.root else {
            throw .formatChanged(detail: "camt.052: XML nicht lesbar (Zeile \(parser.lineNumber))")
        }
        return root
    }

    /// JSON object: attributes as `@name`, text as `#text`, repeated children as arrays.
    func jsonObject() -> Any {
        var object: [String: Any] = [:]
        for (key, value) in attributes { object["@" + key] = value }
        var grouped: [String: [Any]] = [:]
        var order: [String] = []
        for child in children {
            if grouped[child.name] == nil { order.append(child.name) }
            grouped[child.name, default: []].append(child.jsonObject())
        }
        for name in order {
            let values = grouped[name] ?? []
            object[name] = values.count == 1 ? values[0] : values
        }
        let trimmedText = text.trimmed
        if children.isEmpty, attributes.isEmpty { return trimmedText }
        if !trimmedText.isEmpty { object["#text"] = trimmedText }
        return object
    }

    func jsonData() -> Data {
        let object: [String: Any] = [name: jsonObject()]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var stack: [CAMTNode] = []
        var root: CAMTNode?

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            stack.append(CAMTNode(name: elementName, attributes: attributes, children: [], text: ""))
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard !stack.isEmpty else { return }
            stack[stack.count - 1].text += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            guard let node = stack.popLast() else { return }
            if stack.isEmpty {
                root = node
            } else {
                stack[stack.count - 1].children.append(node)
            }
        }
    }
}

fileprivate extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nonEmpty: String? { isEmpty ? nil : self }
}
