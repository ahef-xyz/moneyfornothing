import Foundation
import Testing
@testable import MFNCore

// Synthetic data only (test IBANs, invented names).

private let base = BankDay(year: 2026, month: 10, day: 15)!

private func t(
    _ cents: Int, _ name: String = "", purpose: String? = nil, iban: String? = nil,
    creditor: String? = nil, mref: String? = nil, day: Int = 0, on start: BankDay = base,
    status: TransactionStatus = .booked, category: CategoryID? = nil, source: CategorySource? = nil, confidence: Double? = nil,
    account: AccountID = "giro"
) -> Transaction {
    let key = UUID().uuidString
    let date = start.adding(days: day)
    return Transaction(
        id: TransactionID(key), accountID: account, bookingDate: date, valueDate: date, amountCents: cents,
        counterpartName: name, counterpartIBAN: iban, purpose: purpose ?? "Buchung \(key.prefix(8))", mref: mref, creditorID: creditor,
        status: status, categoryID: category, categorySource: source, confidence: confidence
    )
}

private func t(
    _ account: AccountID, _ cents: Int, _ name: String, purpose: String? = nil, iban: String? = nil, day: Int = 0,
    on start: BankDay = base, status: TransactionStatus = .booked, category: CategoryID? = nil, source: CategorySource? = nil
) -> Transaction {
    t(cents, name, purpose: purpose, iban: iban, day: day, on: start, status: status, category: category, source: source, account: account)
}

private let giroIBAN = "DE02 1203 0000 0000 2020 51"
private let savingsIBAN = "DE02 5001 0517 0137 0750 30"
private let cardIBAN = "DE89 3704 0044 0532 0130 00"
private let foreignIBAN = "DE75 5121 0800 1245 1261 99"

private let accounts: [Account] = [
    Account(id: "giro", connectionID: "c1", iban: giroIBAN, type: .giro, name: "Giro"),
    Account(id: "tagesgeld", connectionID: "c1", iban: savingsIBAN, type: .tagesgeld, name: "Tagesgeld"),
    Account(id: "karte", connectionID: "c2", type: .card, name: "Visa"),
    Account(id: "karte2", connectionID: "c2", iban: cardIBAN, type: .card, name: "Kreditkarte"),
]

private func context(_ transactions: [Transaction]) -> CategorizationContext {
    var snapshot = LedgerSnapshot()
    snapshot.accounts = accounts
    snapshot.transactions = transactions
    return CategorizationContext(snapshot: snapshot)
}

private func transfers(_ transactions: [Transaction]) async -> [TransactionID: CategoryID] {
    await TransferStage().suggest(transactions, context: context(transactions)).mapValues(\.categoryID)
}

private func known(_ name: String, _ cents: Int = -1_234, purpose: String = "") -> CategoryID? {
    KnownMerchants.category(for: t(cents, name, purpose: purpose))
}

// MARK: - Context

@Suite struct CategorizationContextTests {
    @Test func snapshotFillsOwnIBANsAndAllTransactions() {
        let a = t(-100, "A"), cancelled = t(-200, "B", status: .cancelled)
        let ctx = context([a, cancelled])
        #expect(ctx.ownIBANs == ["DE02120300000000202051", "DE02500105170137075030", "DE89370400440532013000"])
        #expect(ctx.ownAccountsByIBAN["DE02500105170137075030"] == "tagesgeld")
        #expect(ctx.recent.map(\.id) == [a.id])
    }

    @Test func memberwiseInitCompactsIBANs() {
        let ctx = CategorizationContext(ownIBANs: ["de02 1203 0000 0000 2020 51"])
        #expect(ctx.ownIBANs == ["DE02120300000000202051"])
    }
}

// MARK: - TransferStage

@Suite struct TransferStageTests {
    @Test func ownIBANIsATransfer() async {
        let out = t("giro", -50_000, "Max Muster", iban: savingsIBAN)
        let back = t("tagesgeld", 50_000, "Max Muster", iban: "de02120300000000202051", day: 5)
        let result = await transfers([out, back])
        #expect(result[out.id] == "umbuchung")
        #expect(result[back.id] == "umbuchung")
        let s = await TransferStage().suggest([out], context: context([out]))
        #expect(s[out.id]?.confidence == 0.95)
        #expect(s[out.id]?.source == .rule)
    }

    @Test func ownCardIBANIsACardSettlement() async {
        let out = t("giro", -80_000, "Kreditkarte", iban: cardIBAN)
        #expect(await transfers([out])[out.id] == "umbuchung")
    }

    @Test func foreignOrMissingIBANWithoutCounterBookingIsNothing() async {
        let rent = t("giro", -90_000, "Vermieter", iban: foreignIBAN)
        let cash = t("giro", -5_000, "Kiosk")
        #expect(await transfers([rent, cash]).isEmpty)
    }

    @Test func ownIBANOfTheSameAccountIsNotATransfer() async {
        let odd = t("giro", -1_000, "Ich", iban: giroIBAN)
        #expect(await transfers([odd]).isEmpty)
    }

    @Test func exactCounterBookingWithinTwoDays() async {
        let out = t("giro", -25_000, "Trade Republic Einzahlung")
        let into = t("tagesgeld", 25_000, "Einzahlung", day: 2)
        let result = await transfers([out, into])
        #expect(result[out.id] == "umbuchung")
        #expect(result[into.id] == "umbuchung")
    }

    @Test func counterBookingThreeDaysApartIsNothing() async {
        let out = t("giro", -25_000, "Übertrag")
        let into = t("tagesgeld", 25_000, "Übertrag", day: 3)
        #expect(await transfers([out, into]).isEmpty)
    }

    @Test func cardSettlementByCounterBookingIsATransfer() async {
        let debit = t("giro", -43_210, "Kreditkartenabrechnung")
        let credit = t("karte", 43_210, "Zahlung erhalten", day: 1)
        let result = await transfers([debit, credit])
        #expect(result[debit.id] == "umbuchung")
        #expect(result[credit.id] == "umbuchung")
    }

    @Test func ambiguousCounterBookingsAreNothing() async {
        // Two candidates for one booking.
        let out = t("giro", -10_000, "Übertrag")
        let a = t("tagesgeld", 10_000, "Eingang", day: 1)
        let b = t("karte", 10_000, "Eingang", day: -1)
        #expect(await transfers([out, a, b]).isEmpty)
        // One candidate, but it has two partners itself.
        let x1 = t("giro", -7_000, "A"), x2 = t("giro", -7_000, "B", day: 1)
        let y = t("tagesgeld", 7_000, "C")
        #expect(await transfers([x1, x2, y]).isEmpty)
    }

    @Test func counterBookingNamingSomeoneElseIsNotATransfer() async {
        let out = t("giro", -3_000, "Freundin", iban: foreignIBAN)
        let into = t("tagesgeld", 3_000, "Freund", iban: "DE12 1001 0010 0123 4567 89")
        #expect(await transfers([out, into]).isEmpty)
    }

    @Test func sameAccountAndCancelledNeverPair() async {
        let out = t("giro", -2_000, "Rückbuchung"), back = t("giro", 2_000, "Rückbuchung")
        #expect(await transfers([out, back]).isEmpty)
        let gone = t("giro", -4_000, "Übertrag", status: .cancelled), into = t("tagesgeld", 4_000, "Übertrag")
        #expect(await transfers([gone, into]).isEmpty)
    }

    @Test func partnerMayAlreadyBeCategorized() async {
        let into = t("tagesgeld", 6_000, "Eingang", category: "umbuchung", source: .manual)
        let out = t("giro", -6_000, "Übertrag")
        let ctx = context([into, out])
        #expect(await TransferStage().suggest([out], context: ctx)[out.id]?.categoryID == "umbuchung")
    }
}

// MARK: - KnownMerchantStage

@Suite struct KnownMerchantTests {
    @Test func listIsLargeAndUsesCatalogIDs() {
        #expect(KnownMerchants.entries.count >= 200)
        for entry in KnownMerchants.entries {
            #expect(CategoryCatalog.info(entry.category) != nil, "\(entry.words)")
            #expect(entry.inflowCategory.map { CategoryCatalog.info($0) != nil } ?? true)
            #expect(!entry.words.isEmpty)
        }
    }

    @Test func normalization() {
        #expect(MerchantText.words("REWE Markt GmbH 4711 Köln") == ["rewe", "markt", "4711", "koeln"])
        #expect(MerchantText.words("Bäckerei") == MerchantText.words("BAECKEREI"))
        #expect(MerchantText.words("REWE1234 KOELN") == ["rewe", "1234", "koeln"])
        #expect(MerchantText.words("O2 Germany") == ["o2", "germany"])
        #expect(MerchantText.words("McDonald's") == ["mcdonalds"])
        #expect(MerchantText.words("VISA Debitkartenumsatz") == [])
    }

    @Test func groceriesAndDrugstores() {
        #expect(known("REWE Markt 4711 Koeln") == "lebensmittel")
        #expect(known("EDEKA Center Mueller") == "lebensmittel")
        #expect(known("LIDL DIENSTL GMBH") == "lebensmittel")
        #expect(known("ALDI SUED SAGT DANKE") == "lebensmittel")
        #expect(known("Stadtbäckerei Krause") == "lebensmittel")
        #expect(known("DM-Drogerie Markt 123") == "drogerie")
        #expect(known("ROSSMANN 2211") == "drogerie")
    }

    @Test func fuelTransportAndMobility() {
        #expect(known("ARAL Station 0815") == "tanken")
        #expect(known("Shell 1234 Berlin") == "tanken")
        #expect(known("DB Vertrieb GmbH") == "oepnv")
        #expect(known("DB BAHN A-NR ABC123") == "oepnv")
        #expect(known("BVG Ticket") == "oepnv")
        #expect(known("Verkehrsverbund Rhein-Sieg") == "oepnv")
        #expect(known("FlixBus") == "oepnv")
        #expect(known("Uber BV") == "taxi_sharing")
        #expect(known("Uber Eats") == "restaurant", "longer pattern wins")
        #expect(known("APCOA Parking") == "auto")
        #expect(known("Parkhaus Altstadt") == "auto")
    }

    @Test func subscriptionsTelecomEnergyInsurance() {
        #expect(known("NETFLIX.COM") == "abos")
        #expect(known("Spotify AB") == "abos")
        #expect(known("APPLE.COM/BILL") == "abos")
        #expect(known("Apple Store Rosenstrasse") == "elektronik")
        #expect(known("Telekom Deutschland GmbH") == "internet_telefon")
        #expect(known("1&1 Telecom GmbH") == "internet_telefon")
        #expect(known("ALDI TALK") == "internet_telefon", "longer than ALDI")
        #expect(known("Stadtwerke Musterstadt") == "nebenkosten")
        #expect(known("E.ON Energie Deutschland") == "nebenkosten")
        #expect(known("HUK-COBURG Versicherung") == "versicherung")
        #expect(known("Haftpflichtversicherung XY") == "versicherung")
        #expect(known("Techniker Krankenkasse") == "versicherung")
        #expect(known("Techniker Krankenkasse", 4_500) == "erstattung", "refund from the health insurer")
    }

    @Test func shoppingLeisureHealthFamily() {
        #expect(known("AMZN Mktp DE") == "online_shopping")
        #expect(known("Amazon Prime") == "abos")
        #expect(known("Amazon.de", 2_999) == "online_shopping", "refund keeps the merchant category")
        #expect(known("Zalando SE") == "kleidung")
        #expect(known("H&M 432") == "kleidung")
        #expect(known("IKEA Deutschland") == "haushalt")
        #expect(known("Globus Baumarkt") == "haushalt", "longer than Globus")
        #expect(known("Globus SB-Warenhaus") == "lebensmittel")
        #expect(known("McDonald's 123") == "restaurant")
        #expect(known("Lieferando.de") == "restaurant")
        #expect(known("Pizzeria Da Mario") == "restaurant")
        #expect(known("CinemaxX Hamburg") == "freizeit")
        #expect(known("McFit GmbH") == "sport")
        #expect(known("Lufthansa") == "reisen")
        #expect(known("Booking.com") == "reisen")
        #expect(known("Löwen-Apotheke") == "gesundheit")
        #expect(known("Zahnarztpraxis Dr. Weiß") == "gesundheit")
        #expect(known("Kita Sonnenschein") == "kinder")
        #expect(known("UNICEF") == "geschenke_spenden")
        #expect(known("Scalable Capital") == "sparen_anlegen")
    }

    @Test func taxesCashFeesInterest() {
        #expect(known("Finanzamt Musterstadt") == "steuern")
        #expect(known("Rundfunk ARD, ZDF, DRadio") == "steuern")
        #expect(known("", purpose: "Rundfunkbeitrag 10.2026-12.2026") == "steuern")
        #expect(known("Bundeskasse", purpose: "Kfz-Steuer M-AB 123") == "steuern")
        #expect(known("", purpose: "GAA 12345 Sparkasse Musterstadt") == "bargeld")
        #expect(known("Bargeldauszahlung") == "bargeld")
        #expect(known("Musterbank", purpose: "Kontoführungsentgelt 10/2026") == "gebuehren")
        #expect(known("Musterbank", 312, purpose: "Habenzinsen") == "zinsen")
        #expect(known("Musterbank", purpose: "DKB Kreditkartenabrechnung") == "kredit")
    }

    @Test func incomeOnlyForInflows() {
        #expect(known("ALDI SE", 250_000, purpose: "Gehalt 10/2026") == "gehalt", "salary from a supermarket")
        #expect(known("Max Muster", -50_000, purpose: "Gehalt Haushaltshilfe") == nil)
        #expect(known("Familienkasse", 25_500, purpose: "Kindergeld") == "einnahmen_sonstige")
        #expect(known("Familienkasse", -25_500) == nil, "income category never on an outflow")
    }

    @Test func paymentServicesAndCardPhrasesUseThePurpose() {
        #expect(known("PayPal Europe S.a.r.l. et Cie S.C.A", purpose: "1234567890 PP.1234.PP . Spotify AB, Ihr Einkauf bei Spotify AB") == "abos")
        #expect(known("PayPal Europe", purpose: "Ihr Einkauf bei Max Muster") == nil)
        #expect(known("VISA Debitkartenumsatz", purpose: "REWE Markt Koeln") == "lebensmittel")
        #expect(known("Max Muster", purpose: "Geld für REWE Einkauf") == nil, "brands in the purpose only behind payment services")
    }

    @Test func negatives() {
        #expect(known("Dbx Studio") == nil, "no DB in Dbx")
        #expect(known("ADB Software") == nil)
        #expect(known("Hans Müller") == nil)
        #expect(known("Norma Schmidt") == nil)
        #expect(known("Otto Meier") == nil)
        #expect(known("Zara Ahmed") == nil)
        #expect(known("Conrad Weber") == nil)
        #expect(known("Rewerk Bau") == nil, "no REWE inside a word")
        #expect(known("Shellfish Bar") == nil)
        #expect(known("Kfz-Werkstatt Becker", purpose: "Rechnung 42") == "auto")
        #expect(known("Max Muster", purpose: "Miete Oktober") == nil, "plain Miete in a purpose is not enough")
        #expect(known("") == nil)
    }

    @Test func stageUsesConfidencePointEight() async {
        let rewe = t(-1_000, "REWE"), other = t(-1_000, "Unbekannt"), gone = t(-1_000, "REWE", status: .cancelled)
        let result = await KnownMerchantStage().suggest([rewe, other, gone], context: CategorizationContext())
        #expect(result[rewe.id] == CategorySuggestion(categoryID: "lebensmittel", source: .rule, confidence: 0.8))
        #expect(result.count == 1)
    }
}

// MARK: - Setup plan

private func service(_ transactions: [Transaction]) async throws -> (CategorizationService, InMemoryLedgerStore) {
    let store = InMemoryLedgerStore()
    try await store.upsert(connection: Connection(id: "c1", connectorID: .mock, displayName: "Bank"))
    try await store.upsert(connection: Connection(id: "c2", connectorID: .mock, displayName: "Karte"))
    try await store.replaceAccounts(accounts.filter { $0.connectionID == "c1" }, of: "c1")
    try await store.replaceAccounts(accounts.filter { $0.connectionID == "c2" }, of: "c2")
    try await store.apply(TransactionMerger.Result(upserts: transactions, deletions: [], resolved: [:]))
    let categorizer = Categorizer(stages: [RuleStage(), TransferStage(), KnownMerchantStage()])
    return (CategorizationService(store: store, categorizer: categorizer), store)
}

private func monthly(_ months: Int, _ make: (BankDay, Int) -> Transaction) -> [Transaction] {
    (0..<months).map { make(base.adding(months: -$0), $0) }
}

@Suite struct SetupPlanTests {
    static func ledger() -> [Transaction] {
        var all: [Transaction] = []
        // Salary, 6 months, slightly varying.
        all += monthly(6) { d, i in t(320_000 + i * 1_000, "Muster Software GmbH", purpose: "Lohn/Gehalt \(i)", iban: "DE44 5001 0517 5407 3249 31", on: d) }
        // Child benefit: recurring income, no salary.
        all += monthly(6) { d, i in t(25_500, "Familienkasse", purpose: "Kindergeld \(i)", on: d) }
        // Rent by standing order (no creditor ID), stable.
        all += monthly(6) { d, i in t(-95_000, "Hausverwaltung Beispiel", purpose: "Miete \(i)", iban: foreignIBAN, on: d.adding(days: 1)) }
        // Energy direct debit.
        all += monthly(6) { d, i in t(-8_500 - (i % 2) * 500, "Stadtwerke Musterstadt", purpose: "Abschlag \(i)", creditor: "DE98ZZZ09999999999", mref: "M-1", on: d.adding(days: 2)) }
        // PayPal: many direct debits a month, any amount → counterparty.
        for i in 0..<12 { all.append(t(-(1_000 + i * 731), "PayPal Europe", purpose: "PP \(i)", creditor: "LU96ZZZ0000000000000000058", mref: "P-\(i)", day: -i * 7)) }
        // Groceries.
        for i in 0..<20 { all.append(t(-(2_000 + i * 113), "REWE Markt \(4_000 + i % 3) Koeln", day: -i * 3)) }
        // A café nobody knows.
        for i in 0..<4 { all.append(t(-450, "Kaffeerösterei Bohne", day: -i * 5)) }
        // Transfers to own savings (IBAN) and the counter side without IBAN.
        all += monthly(3) { d, i in t(-20_000, "Max Muster", purpose: "Sparen \(i)", iban: savingsIBAN, on: d.adding(days: 3)) }
        all += monthly(3) { d, i in t("tagesgeld", 20_000, "Max Muster", purpose: "Sparen \(i)", iban: giroIBAN, on: d.adding(days: 4)) }
        // Card settlement by counter-booking.
        all += monthly(3) { d, i in t(-(30_000 + i * 2_345), "Visa Abrechnung", purpose: "Abrechnung \(i)", on: d.adding(days: 6)) }
        all += monthly(3) { d, i in t("karte", 30_000 + i * 2_345, "", purpose: "Ausgleich", on: d.adding(days: 7)) }
        // Already done: manual and trusted rule categories are not part of the plan.
        all.append(t(-1_500, "Kiosk", category: "freizeit", source: .manual, confidence: 1))
        all.append(t(-1_700, "Bäcker", category: "lebensmittel", source: .rule, confidence: 0.8))
        all.append(t(-1_900, "Unsicher", category: "sonstiges", source: .llm, confidence: 0.4))
        all.append(t(-9_999, "Storno", status: .cancelled))
        return all
    }

    @Test func kindsAndUniqueAssignment() async throws {
        let all = Self.ledger()
        let (service, _) = try await service(all)
        let plan = await service.setupPlan()

        let ids = plan.candidates.flatMap(\.transactionIDs)
        #expect(Set(ids).count == ids.count, "every transaction in at most one candidate")
        #expect(Set(plan.candidates.map(\.id)).count == plan.candidates.count)
        #expect(plan.totalTransactions == all.count - 1)
        #expect(plan.categorizedTransactions == 2)

        func candidate(_ title: String) -> SetupPlan.Candidate? { plan.candidates.first { $0.title.contains(title) } }

        let salary = try #require(candidate("Muster Software"))
        #expect(salary.kind == .income)
        #expect(salary.suggestion?.categoryID == "gehalt")
        #expect(salary.monthlyCents == 322_500, "median of 320_000…325_000")
        #expect(salary.alternatives.first == "gehalt")

        let benefit = try #require(candidate("Familienkasse"))
        #expect(benefit.kind == .income)
        #expect(benefit.suggestion?.categoryID == "einnahmen_sonstige")

        let rent = try #require(candidate("Hausverwaltung"))
        #expect(rent.kind == .fixedCost)
        #expect(rent.monthlyCents == -95_000)
        #expect(rent.match == .counterpartIBAN("DE75512108001245126199"))
        #expect(rent.suggestion?.categoryID == "miete")

        let energy = try #require(candidate("Stadtwerke"))
        #expect(energy.kind == .fixedCost)
        #expect(energy.match == .creditorID("DE98ZZZ09999999999"))
        #expect(energy.monthlyCents == -8_750)
        #expect(energy.suggestion?.categoryID == "nebenkosten")

        #expect(candidate("PayPal")?.kind == .counterparty)
        let rewe = try #require(candidate("REWE"))
        #expect(rewe.kind == .counterparty)
        #expect(rewe.transactionIDs.count == 20)
        #expect(rewe.match == .counterpart("REWE Markt"))
        #expect(rewe.suggestion?.categoryID == "lebensmittel")
        #expect(candidate("Kaffeerösterei")?.suggestion == nil)

        let transfers = plan.candidates(.transfer)
        let savings = try #require(transfers.first { $0.match == .counterpartIBAN("DE02500105170137075030") })
        #expect(savings.title.hasSuffix(": Tagesgeld"))
        #expect(savings.transactionIDs.count == 3)
        #expect(savings.suggestion?.categoryID == "umbuchung")
        #expect(transfers.contains { $0.match == .counterpartIBAN("DE02120300000000202051") })
        let settlement = try #require(transfers.first { $0.title == "Visa Abrechnung" })
        #expect(settlement.suggestion?.categoryID == "umbuchung")
        #expect(transfers.contains { $0.suggestion?.categoryID == "umbuchung" && $0.match == .purpose("Ausgleich") })

        // Kinds come in order.
        let order = plan.candidates.map(\.kind)
        let rank: [SetupPlan.Candidate.Kind: Int] = [.transfer: 0, .income: 1, .fixedCost: 2, .counterparty: 3]
        #expect(order.map { rank[$0] ?? 9 } == order.map { rank[$0] ?? 9 }.sorted())

        // The uncertain LLM guess is open and grouped; its guess is among the alternatives.
        let unsure = try #require(candidate("Unsicher"))
        #expect(unsure.alternatives.first == "sonstiges")

        let covered = Set(ids).count
        #expect(abs(plan.projectedCoverage - Double(2 + covered) / Double(plan.totalTransactions)) < 1e-9)
        #expect(plan.projectedCoverage == 1, "everything open is in some candidate here")
    }

    @Test func alternativesRespectDirectionAndLimit() async throws {
        let (service, _) = try await service(Self.ledger())
        let plan = await service.setupPlan()
        for candidate in plan.candidates {
            #expect(candidate.alternatives.count <= 9)
            #expect(Set(candidate.alternatives).count == candidate.alternatives.count)
            if let suggestion = candidate.suggestion { #expect(candidate.alternatives.first == suggestion.categoryID) }
            if candidate.totalCents < 0 {
                #expect(!candidate.alternatives.contains { CategoryCatalog.info($0)?.isIncome == true }, "\(candidate.title)")
            }
        }
        let rewe = try #require(plan.candidates.first { $0.title.contains("REWE") })
        #expect(rewe.alternatives.count == 9)
        let salary = try #require(plan.candidates.first { $0.kind == .income })
        #expect(salary.alternatives.contains("einnahmen_sonstige"))
    }

    @Test func limitCutsCounterpartiesFirstAndProjectionFollows() async throws {
        let (service, _) = try await service(Self.ledger())
        let plan = await service.setupPlan(limit: 3)
        #expect(plan.candidates.count == 3)
        #expect(plan.candidates.allSatisfy { $0.kind == .transfer })
        let covered = Set(plan.candidates.flatMap(\.transactionIDs)).count
        #expect(abs(plan.projectedCoverage - Double(2 + covered) / Double(plan.totalTransactions)) < 1e-9)
        #expect(await service.setupPlan(limit: 0).candidates.isEmpty)
    }

    @Test func transferRuleThatWouldHitPaymentsIsLeftOut() async throws {
        // Counter-booking by name only; the same name also pays a stranger.
        let out = t(-12_300, "Max Muster", purpose: "Übertrag")
        let into = t("tagesgeld", 12_300, "Max Muster", purpose: "Übertrag", day: 1)
        let other = t(-4_000, "Max Muster", purpose: "Übertrag", day: -20)
        let (service, _) = try await service([out, into, other])
        let plan = await service.setupPlan()
        #expect(plan.candidates(.transfer).isEmpty)
        let ids = plan.candidates.flatMap(\.transactionIDs)
        #expect(Set(ids) == [out.id, into.id, other.id], "they stay in the plan as a counterparty")
    }

    @Test func singleMonthOrUnstablePaymentsAreNoFixedCost() async throws {
        var all: [Transaction] = []
        // Same amount, but only two months without a mandate.
        all += monthly(2) { d, _ in t(-1_299, "Fitnessstudio Nord", purpose: "Beitrag", on: d) }
        // Direct debit, wildly varying amounts.
        all += monthly(4) { d, i in t(-(500 + i * 4_000), "Versandhaus", purpose: "Rechnung", creditor: "DE11ZZZ00000000001", on: d) }
        let (service, _) = try await service(all)
        let plan = await service.setupPlan()
        #expect(plan.candidates.allSatisfy { $0.kind == .counterparty })
    }

    @Test func twoThousandTransactionsAreQuick() async throws {
        var all: [Transaction] = []
        let names = ["REWE Markt", "Lidl", "Aral", "Netflix", "Amazon", "DB Vertrieb", "Café Jansen", "Kiosk Eck", "Shell", "IKEA"]
        for i in 0..<2_000 {
            let start = base.adding(days: -(i % 540))
            switch i % 20 {
            case 0: all.append(t(300_000, "Arbeitgeber \(i % 3)", purpose: "Gehalt", on: start))
            case 1: all.append(t(-9_500, "Vermieter \(i % 2)", iban: "DE75512108001245126\(100 + i % 2)", on: start))
            case 2: all.append(t(-(2_000 + i), "Versicherung \(i % 7)", creditor: "DE00ZZZ0000000\(i % 7)", on: start))
            case 3: all.append(t(-5_000, "Übertrag", purpose: "Sparen \(i)", iban: savingsIBAN, on: start))
            default: all.append(t(-(100 + i), "\(names[i % names.count]) \(i % 50)", purpose: "Karte \(i)", on: start))
            }
        }
        let (service, _) = try await service(all)
        let clock = ContinuousClock()
        let start = clock.now
        let plan = await service.setupPlan()
        let elapsed = clock.now - start
        #expect(elapsed < .seconds(1), "setupPlan for 2.000 transactions took \(elapsed)")
        #expect(plan.totalTransactions == 2_000)
        #expect(!plan.candidates.isEmpty)
        print("setupPlan 2.000 Umsätze: \(elapsed), \(plan.candidates.count) Kandidaten, projiziert \(plan.projectedCoverage)")
    }
}
