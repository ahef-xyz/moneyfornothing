import Foundation

/// One category of the fixed catalog. `id` is what `Transaction.categoryID` stores.
public struct CategoryInfo: Hashable, Sendable, Identifiable {
    public let id: CategoryID
    /// German title shown in the UI.
    public let title: String
    /// Title in the user's language. `title` stays German (stable key for CSV round trips and
    /// matching); the database stores only `id`, so display code should use this.
    public var localizedTitle: String { CategoryCatalog.localizedTitle(id) }
    public let group: Group
    /// SF Symbol name.
    public let symbol: String
    /// Money usually comes in (salary, refunds); used for plausibility, not as a hard rule.
    public let isIncome: Bool

    public enum Group: String, CaseIterable, Hashable, Sendable {
        case einnahmen, wohnen, lebenshaltung, mobilitaet, freizeit, einkaufen, gesundheit, familie, finanzen, sonstiges

        /// Group title in the user's language (see `title`).
        public var localizedTitle: String { Self.localizedTitles[self] ?? title }

        private static let localizedTitles: [Group: String] = Dictionary(uniqueKeysWithValues: allCases.map {
            ($0, String(localized: String.LocalizationValue($0.title), bundle: .module))
        })

        public var title: String {
            switch self {
            case .einnahmen: "Einnahmen"
            case .wohnen: "Wohnen"
            case .lebenshaltung: "Lebenshaltung"
            case .mobilitaet: "Mobilität"
            case .freizeit: "Freizeit"
            case .einkaufen: "Einkaufen"
            case .gesundheit: "Gesundheit"
            case .familie: "Familie"
            case .finanzen: "Finanzen"
            case .sonstiges: "Sonstiges"
            }
        }
    }
}

/// The fixed category catalog (Phase 3). Source of truth for the rule engine, kNN, the
/// Foundation Models `@Generable` enum (must mirror `all` 1:1, checked by a test) and the UI.
/// IDs are stable: never rename one that shipped; add new ones at the end of their group.
public enum CategoryCatalog {
    public static let all: [CategoryInfo] = [
        c("gehalt", "Gehalt & Lohn", .einnahmen, "briefcase", income: true),
        c("erstattung", "Erstattungen", .einnahmen, "arrow.uturn.backward.circle", income: true),
        c("zinsen", "Zinsen & Dividenden", .einnahmen, "percent", income: true),
        c("einnahmen_sonstige", "Sonstige Einnahmen", .einnahmen, "plus.circle", income: true),

        c("miete", "Miete & Wohnkredit", .wohnen, "house"),
        c("nebenkosten", "Strom, Gas & Wasser", .wohnen, "bolt"),
        c("internet_telefon", "Internet & Telefon", .wohnen, "wifi"),
        c("haushalt", "Haushalt & Einrichtung", .wohnen, "sofa"),

        c("lebensmittel", "Lebensmittel", .lebenshaltung, "cart"),
        c("restaurant", "Restaurant & Café", .lebenshaltung, "fork.knife"),
        c("drogerie", "Drogerie", .lebenshaltung, "drop"),

        c("tanken", "Tanken & Laden", .mobilitaet, "fuelpump"),
        c("oepnv", "ÖPNV & Bahn", .mobilitaet, "tram"),
        c("auto", "Auto & Werkstatt", .mobilitaet, "car"),
        c("taxi_sharing", "Taxi & Sharing", .mobilitaet, "car.side"),

        c("abos", "Abos & Streaming", .freizeit, "play.rectangle"),
        c("freizeit", "Freizeit & Kultur", .freizeit, "theatermasks"),
        c("sport", "Sport & Fitness", .freizeit, "figure.run"),
        c("reisen", "Reisen & Urlaub", .freizeit, "airplane"),

        c("kleidung", "Kleidung", .einkaufen, "tshirt"),
        c("elektronik", "Elektronik & Software", .einkaufen, "desktopcomputer"),
        c("online_shopping", "Online-Shopping", .einkaufen, "shippingbox"),

        c("gesundheit", "Arzt & Apotheke", .gesundheit, "cross.case"),
        c("versicherung", "Versicherungen", .gesundheit, "shield"),

        c("kinder", "Kinder & Betreuung", .familie, "figure.and.child.holdinghands"),
        c("geschenke_spenden", "Geschenke & Spenden", .familie, "gift"),

        c("umbuchung", "Umbuchung (eigene Konten)", .finanzen, "arrow.left.arrow.right"),
        c("sparen_anlegen", "Sparen & Anlegen", .finanzen, "chart.line.uptrend.xyaxis"),
        c("kredit", "Kredit & Kreditkarte", .finanzen, "creditcard"),
        c("gebuehren", "Bankgebühren", .finanzen, "building.columns"),
        c("steuern", "Steuern & Abgaben", .finanzen, "doc.text"),
        c("bargeld", "Bargeld", .finanzen, "banknote"),

        c("sonstiges", "Sonstiges", .sonstiges, "questionmark.circle"),
    ]

    private static let byID: [CategoryID: CategoryInfo] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    public static func info(_ id: CategoryID) -> CategoryInfo? { byID[id] }

    /// Title for any ID, also unknown ones (from an older catalog).
    public static func title(_ id: CategoryID) -> String { byID[id]?.title ?? id.rawValue }

    /// Display title for any ID in the user's language; built-in categories are looked up in the
    /// catalog, unknown IDs fall back to the ID itself. Nothing is stored translated.
    public static func localizedTitle(_ id: CategoryID) -> String {
        localizedTitles[id] ?? id.rawValue
    }

    private static let localizedTitles: [CategoryID: String] = Dictionary(uniqueKeysWithValues: all.map {
        ($0.id, String(localized: String.LocalizationValue($0.title), bundle: .module))
    })

    private static func c(_ id: String, _ title: String, _ group: CategoryInfo.Group, _ symbol: String, income: Bool = false) -> CategoryInfo {
        CategoryInfo(id: CategoryID(id), title: title, group: group, symbol: symbol, isIncome: income)
    }
}
