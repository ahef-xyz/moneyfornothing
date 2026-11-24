import FoundationModels
import MFNCore

/// The catalog as a `@Generable` enum: the model can only answer with a catalog ID.
/// Must mirror `CategoryCatalog.all` 1:1 and in order (checked by `LLMCategoryTests`).
@Generable
public enum LLMCategory: String, CaseIterable, Sendable {
    case gehalt
    case erstattung
    case zinsen
    case einnahmen_sonstige

    case miete
    case nebenkosten
    case internet_telefon
    case haushalt

    case lebensmittel
    case restaurant
    case drogerie

    case tanken
    case oepnv
    case auto
    case taxi_sharing

    case abos
    case freizeit
    case sport
    case reisen

    case kleidung
    case elektronik
    case online_shopping

    case gesundheit
    case versicherung

    case kinder
    case geschenke_spenden

    case umbuchung
    case sparen_anlegen
    case kredit
    case gebuehren
    case steuern
    case bargeld

    case sonstiges

    public var categoryID: CategoryID { CategoryID(rawValue) }
}

/// One answer per booking, referenced by its number in the prompt.
@Generable
public struct LLMAssignment: Sendable {
    @Guide(description: "Nummer der Buchung")
    public var nummer: Int
    public var kategorie: LLMCategory
    @Guide(description: "Sicherheit 0 bis 100", .range(0 ... 100))
    public var sicherheit: Int

    public init(nummer: Int, kategorie: LLMCategory, sicherheit: Int) {
        self.nummer = nummer
        self.kategorie = kategorie
        self.sicherheit = sicherheit
    }
}

@Generable
public struct LLMBatchAnswer: Sendable {
    @Guide(description: "Genau eine Zuordnung je Buchung")
    public var zuordnungen: [LLMAssignment]

    public init(zuordnungen: [LLMAssignment]) {
        self.zuordnungen = zuordnungen
    }
}
