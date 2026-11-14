import Foundation
import MFNCore

// Tolerant models for the GraphQL answers (`Fixtures/N26/feed-*.json`, `timeline-*.json`): unknown fields are
// ignored, everything optional that the UI-oriented feed might leave out. Only what MFN needs is decoded.

struct N26Money: Decodable, Sendable, Equatable {
    struct Currency: Decodable, Sendable, Equatable {
        var code: String?
        var decimals: Int?
    }

    /// Minor units as decimal string (`"-1299"`), occasionally a number.
    var unscaledAmount: N26Integer?
    var currency: Currency?

    /// Exact cents (MFN stores cents; N26 sends 2 decimals for EUR). Never via Double.
    func cents(context: String) throws(ConnectorError) -> Int {
        guard let unscaled = unscaledAmount?.value else { throw .formatChanged(detail: "N26 \(context): Betrag fehlt") }
        let decimals = currency?.decimals ?? 2
        switch decimals {
        case 2:
            return unscaled
        case 0, 1:
            let (product, overflow) = unscaled.multipliedReportingOverflow(by: decimals == 0 ? 100 : 10)
            guard !overflow else { throw .formatChanged(detail: "N26 \(context): Betrag zu groß") }
            return product
        case 3...9:
            var divisor = 1
            for _ in 0..<(decimals - 2) { divisor *= 10 }
            guard unscaled % divisor == 0 else { throw .formatChanged(detail: "N26 \(context): Betrag unter 1 Cent") }
            return unscaled / divisor
        default:
            throw .formatChanged(detail: "N26 \(context): \(decimals) Nachkommastellen")
        }
    }
}

/// Integer sent as string or number.
struct N26Integer: Decodable, Sendable, Equatable {
    var value: Int?

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Int.self) {
            value = number
        } else if let text = try? container.decode(String.self) {
            value = Int(text.trimmingCharacters(in: .whitespaces))
        } else {
            value = nil
        }
    }
}

struct N26Feed: Decodable, Sendable {
    struct Balance: Decodable, Sendable {
        var title: String?
        var money: N26Money?
    }

    struct Activities: Decodable, Sendable {
        var values: [Activity]?
    }

    /// One entry of the account switcher: „Alle Aktivitäten“ (no ID), „Hauptkonto“ (MAIN), Spaces (SPACE).
    struct Activity: Decodable, Sendable {
        struct Tracking: Decodable, Sendable {
            var label: String?
        }

        var title: String?
        var accountId: String?
        var tracking: Tracking?

        var kind: N26AccountKind { N26AccountKind(label: tracking?.label) }
    }

    var balance: Balance?
    var activities: Activities?
}

enum N26AccountKind: Equatable, Sendable {
    case main
    case space
    case all
    case unknown(String)

    init(label: String?) {
        switch label?.uppercased() {
        case "MAIN": self = .main
        case "SPACE": self = .space
        case "ALL", nil: self = .all
        case let other?: self = .unknown(other)
        }
    }
}

/// `FeedTimelineTransaction`. Group headings (`FeedTimelineGroupHeading`) are skipped before decoding.
struct N26TimelineTransaction: Decodable, Sendable {
    struct Subtitle: Decodable, Sendable {
        struct Element: Decodable, Sendable {
            var value: String?
        }

        var elements: [Element]?

        var text: String {
            (elements ?? []).compactMap { $0.value?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " ")
        }
    }

    struct StyledAmount: Decodable, Sendable {
        var money: N26Money?
        var appearance: String?
    }

    struct Icon: Decodable, Sendable {
        struct Status: Decodable, Sendable {
            var lightUrl: String?
        }

        var type: String?
        var statusIcon: Status?
    }

    var externalId: String?
    var accountId: String?
    var title: String?
    var tintedSubtitle: Subtitle?
    var secondarySubtitle: Subtitle?
    var styledAmount: StyledAmount?
    var type: String?
    /// Milliseconds since 1970 (transaction time).
    var timestamp: Int64?
    var customReferenceText: String?
    var category: String?
    var icon: Icon?
}

// MARK: - Raw JSON access

enum N26JSON {
    /// Root object of a GraphQL answer; `errors` mapped to `ConnectorError`.
    /// „401 Unauthorized“ (what the web app treats as logout) → `sessionExpired`. Messages never leave this function.
    static func data(_ body: Data, operation: String) throws(ConnectorError) -> [String: Any] {
        guard let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            throw .formatChanged(detail: "N26 \(operation): kein gültiges JSON")
        }
        if let errors = root["errors"] as? [[String: Any]], !errors.isEmpty {
            let messages = errors.compactMap { $0["message"] as? String }
            let codes = errorCodes(errors)
            if !codes.isEmpty {
                Log.logger("n26").notice("N26 \(operation, privacy: .public): GraphQL-Fehlercodes \(codes.joined(separator: ","), privacy: .public)")
            }
            if messages.contains(where: { $0.contains("401") || $0.contains("403") || $0.localizedCaseInsensitiveContains("unauthorized") || $0.localizedCaseInsensitiveContains("unauthenticated") || $0.localizedCaseInsensitiveContains("forbidden") })
                || codes.contains(where: { $0.contains("UNAUTH") || $0.contains("FORBIDDEN") || $0 == "401" || $0 == "403" }) {
                throw .sessionExpired
            }
            // Live 2026-11-10: an expired session answers `data: {feed: null}` plus an error whose
            // message names neither 401 nor "unauthorized". Every requested field null + errors
            // means the request was refused: treat as expired (the connector re-reads its keys,
            // then logs in once; a fresh session refused this way ends as `authFailed`).
            if let data = root["data"] as? [String: Any], !data.isEmpty, data.values.allSatisfy({ $0 is NSNull }) {
                throw .sessionExpired
            }
            if root["data"] == nil || root["data"] is NSNull {
                throw .formatChanged(detail: "N26 \(operation): GraphQL-Fehler")
            }
        }
        guard let data = root["data"] as? [String: Any] else {
            throw .formatChanged(detail: "N26 \(operation): data fehlt")
        }
        return data
    }

    /// `extensions.code` (and `extensions.status`) of GraphQL errors: enum-like, safe to log.
    /// Anything else (message texts) never leaves `data(_:operation:)`.
    static func errorCodes(_ errors: [[String: Any]]) -> [String] {
        errors.compactMap { error -> String? in
            guard let extensions = error["extensions"] as? [String: Any] else { return nil }
            let raw = (extensions["code"] as? String) ?? (extensions["status"] as? NSNumber)?.stringValue
            guard let code = raw, code.count <= 40,
                  code.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" }) else { return nil }
            return code.uppercased()
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, from object: Any, context: String) throws(ConnectorError) -> T {
        guard JSONSerialization.isValidJSONObject(object), let data = try? JSONSerialization.data(withJSONObject: object) else {
            throw .formatChanged(detail: "N26 \(context): kein Objekt")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch let DecodingError.typeMismatch(_, context2) {
            throw .formatChanged(detail: "N26 \(context): Typ geändert bei \(path(context2.codingPath))")
        } catch let DecodingError.keyNotFound(key, context2) {
            throw .formatChanged(detail: "N26 \(context): Feld fehlt \(path(context2.codingPath + [key]))")
        } catch {
            throw .formatChanged(detail: "N26 \(context): nicht lesbar")
        }
    }

    static func raw(_ object: Any) -> Data? {
        guard JSONSerialization.isValidJSONObject(object) else { return nil }
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private static func path(_ keys: [any CodingKey]) -> String {
        keys.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
    }
}

/// One page of the timeline: transactions with their raw JSON plus the key of the next (older) page.
struct N26TimelinePage: Sendable {
    var items: [(value: N26TimelineTransaction, raw: Data)]
    var paginationKey: String?

    /// From `data.feed.modules[FeedTimelineModule]` (first page) or `data.timeline` (`getTimeline`).
    init(timelineContainer container: [String: Any]?, context: String) throws(ConnectorError) {
        guard let container else {
            items = []
            paginationKey = nil
            return
        }
        paginationKey = (container["paginationKey"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        var items: [(value: N26TimelineTransaction, raw: Data)] = []
        let list = container["timelineItems"] as? [Any] ?? []
        for (index, element) in list.enumerated() {
            guard let object = element as? [String: Any] else {
                throw .formatChanged(detail: "N26 \(context): timelineItems[\(index)] ist kein Objekt")
            }
            guard object["__typename"] as? String == "FeedTimelineTransaction" else { continue } // headings, unknown
            guard let raw = N26JSON.raw(object) else { throw .formatChanged(detail: "N26 \(context): timelineItems[\(index)]") }
            items.append((try N26JSON.decode(N26TimelineTransaction.self, from: object, context: "\(context) timelineItems[\(index)]"), raw))
        }
        self.items = items
    }

    /// First page inside the feed: the `FeedTimelineModule`. No module → empty account.
    static func fromFeed(_ feed: [String: Any]) throws(ConnectorError) -> N26TimelinePage {
        let modules = feed["modules"] as? [[String: Any]] ?? []
        let timeline = modules.first { $0["__typename"] as? String == "FeedTimelineModule" }
        return try N26TimelinePage(timelineContainer: timeline, context: "Feed")
    }
}

// MARK: - Mapping

enum N26Mapper {
    /// Status icons / subtitles that mark a transaction as not yet booked.
    /// UNVERIFIED: the HAR has no pending transaction (only `installment_eligible.png`). Candidates follow the
    /// app's wording („Ausstehend“, „Vorgemerkt“) and a status icon named `pending…`.
    static let pendingMarkers = ["pending", "authoriz", "authoris", "reserved"]
    /// Subtitles are free text (reference): only an exact status word counts.
    static let pendingSubtitles: Set<String> = ["ausstehend", "vorgemerkt", "pending"]

    static func isPending(_ item: N26TimelineTransaction) -> Bool {
        let codes = [item.icon?.statusIcon?.lightUrl.map { URL(string: $0)?.lastPathComponent ?? $0 }, item.type]
        if codes.compactMap({ $0?.lowercased() }).contains(where: { code in pendingMarkers.contains { code.contains($0) } }) {
            return true
        }
        return [item.tintedSubtitle?.text, item.secondarySubtitle?.text].contains { pendingSubtitles.contains($0?.lowercased() ?? "") }
    }

    static func transaction(_ item: N26TimelineTransaction, raw: Data, account: Account) throws(ConnectorError) -> Transaction {
        guard let millis = item.timestamp else { throw .formatChanged(detail: "N26 Umsätze: timestamp fehlt") }
        guard let money = item.styledAmount?.money else { throw .formatChanged(detail: "N26 Umsätze: styledAmount fehlt") }
        let day = BankDay(Date(timeIntervalSince1970: TimeInterval(millis) / 1000))
        let pending = isPending(item)
        let reference = [item.tintedSubtitle?.text, item.customReferenceText].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let purpose = reference.isEmpty ? (item.secondarySubtitle?.text ?? "") : reference.joined(separator: " ")
        return Transaction(
            accountID: account.id,
            bookingDate: pending ? nil : day,
            valueDate: day, // The feed has one date per transaction.
            amountCents: try money.cents(context: "Umsätze"),
            currency: money.currency?.code ?? account.currency,
            counterpartName: item.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            purpose: purpose,
            status: pending ? .pending : .booked,
            externalID: item.externalId.flatMap { $0.isEmpty ? nil : $0 },
            rawJSON: raw
        )
    }
}
