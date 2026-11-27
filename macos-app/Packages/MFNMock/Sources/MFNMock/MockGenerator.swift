import Foundation
import MFNCore

/// Builds `MockDataset`. Deterministic for a given seed and `today`.
struct MockGenerator {
    static let historyMonths = 18

    private var rng: SeededRandom
    private let today: BankDay
    private let now: Date
    private let firstDay: BankDay
    private var sequence = 0
    private var transactions: [AccountID: [Transaction]] = [:]

    init(seed: UInt64, today: BankDay, now: Date) {
        self.rng = SeededRandom(seed: seed)
        self.today = today
        self.now = now
        self.firstDay = today.adding(months: -Self.historyMonths)
    }

    // MARK: - World

    private static let connections: [Connection] = [
        Connection(id: MockConnections.ing, connectorID: .ing, displayName: "ING"),
        Connection(id: MockConnections.dkb, connectorID: .dkb, displayName: "DKB"),
        Connection(id: MockConnections.tradeRepublic, connectorID: .tradeRepublic, displayName: "Trade Republic"),
        Connection(id: MockConnections.c24, connectorID: .c24, displayName: "C24"),
        Connection(id: MockConnections.easybank, connectorID: .easybank, displayName: "easybank"),
        Connection(id: MockConnections.paypal, connectorID: .paypal, displayName: "PayPal"),
        // v12: a bank reached over YAXI (0.7.0); the mock connector serves it, no YAXI key, no network.
        Connection(id: MockConnections.sparkasse, connectorID: .yaxi, displayName: "YAXI: Sparkasse"),
    ]

    private static let accounts: [Account] = [
        Account(id: MockAccounts.ingGiro, connectionID: MockConnections.ing, iban: "DE00 5001 0517 0000 0000 01", type: .giro, name: "Girokonto"),
        Account(id: MockAccounts.ingExtra, connectionID: MockConnections.ing, iban: "DE00 5001 0517 0000 0000 02", type: .tagesgeld, name: "Extra-Konto"),
        Account(id: MockAccounts.dkbGiro, connectionID: MockConnections.dkb, iban: "DE00 1203 0000 0000 0000 03", type: .giro, name: "Girokonto"),
        Account(id: MockAccounts.dkbVisa, connectionID: MockConnections.dkb, type: .card, name: "Visa Kreditkarte", cardLast4: "4417", creditLimitCents: 500_000),
        Account(id: MockAccounts.dkbDepot, connectionID: MockConnections.dkb, type: .depot, name: "Depot"),
        Account(id: MockAccounts.trCash, connectionID: MockConnections.tradeRepublic, iban: "DE00 1001 0000 0000 0000 04", type: .giro, name: "Verrechnungskonto", cardLast4: "9031"),
        Account(id: MockAccounts.trDepot, connectionID: MockConnections.tradeRepublic, type: .depot, name: "Depot"),
        Account(id: MockAccounts.c24Giro, connectionID: MockConnections.c24, iban: "DE00 5002 4024 0000 0000 05", type: .giro, name: "Smartkonto"),
        Account(id: MockAccounts.c24Pocket, connectionID: MockConnections.c24, type: .tagesgeld, name: "Pocket Urlaub"),
        Account(id: MockAccounts.easyVisa, connectionID: MockConnections.easybank, type: .card, name: "Visa Card", cardLast4: "7302", creditLimitCents: 300_000),
        Account(id: MockAccounts.easyTagesgeld, connectionID: MockConnections.easybank, iban: "DE00 2002 0000 0000 0000 06", type: .tagesgeld, name: "Tagesgeld"),
        Account(id: MockAccounts.paypal, connectionID: MockConnections.paypal, type: .giro, name: "PayPal"),
        Account(id: MockAccounts.sparkasseGiro, connectionID: MockConnections.sparkasse, iban: "DE00 3705 0198 0000 0000 07", type: .giro, name: "Girokonto"),
        Account(id: MockAccounts.sparkasseTagesgeld, connectionID: MockConnections.sparkasse, iban: "DE00 3705 0198 0000 0000 08", type: .tagesgeld, name: "Tagesgeld"),
    ]

    private static let openingBalances: [AccountID: Int] = [
        MockAccounts.ingGiro: 420_000,
        MockAccounts.ingExtra: 800_000,
        MockAccounts.dkbGiro: 150_000,
        MockAccounts.dkbVisa: 0,
        MockAccounts.trCash: 120_000,
        MockAccounts.c24Giro: 60_000,
        MockAccounts.c24Pocket: 30_000,
        MockAccounts.easyVisa: 0,
        MockAccounts.easyTagesgeld: 1_500_000,
        MockAccounts.paypal: 8_500,
        MockAccounts.sparkasseGiro: 300_000,
        MockAccounts.sparkasseTagesgeld: 500_000,
    ]

    private static let overdrafts: [AccountID: Int] = [
        MockAccounts.ingGiro: 200_000,
        MockAccounts.dkbGiro: 100_000,
    ]

    // MARK: - Merchants

    struct Merchant {
        let name: String
        /// Longer name used on the final booking (reservation shows the short one).
        let bookedName: String
        let cents: ClosedRange<Int>
        let purpose: String
    }

    static let groceries: [Merchant] = [
        Merchant(name: "REWE Markt", bookedName: "REWE Markt GmbH sagt Danke", cents: 840...9_800, purpose: "Lebensmittel"),
        Merchant(name: "EDEKA", bookedName: "EDEKA Center Sonnenberg", cents: 620...7_400, purpose: "Einkauf"),
        Merchant(name: "Lidl", bookedName: "Lidl sagt Danke", cents: 450...6_200, purpose: "Einkauf"),
        Merchant(name: "ALDI SUED", bookedName: "ALDI SUED Filiale 112", cents: 390...5_800, purpose: "Einkauf"),
        Merchant(name: "dm-drogerie markt", bookedName: "dm-drogerie markt sagt Danke", cents: 280...3_900, purpose: "Drogerie"),
        Merchant(name: "Bäckerei Kamps", bookedName: "Bäckerei Kamps Filiale", cents: 180...1_200, purpose: "Backwaren"),
    ]

    static let everyday: [Merchant] = [
        Merchant(name: "Aral Station", bookedName: "Aral Station 0815", cents: 3_500...8_900, purpose: "Tankstelle"),
        Merchant(name: "Shell", bookedName: "Shell Deutschland Station", cents: 3_200...8_400, purpose: "Tankstelle"),
        Merchant(name: "DB Vertrieb", bookedName: "DB Vertrieb GmbH", cents: 1_990...12_900, purpose: "Fahrkarte"),
        Merchant(name: "Apotheke am Markt", bookedName: "Apotheke am Markt", cents: 450...4_800, purpose: "Apotheke"),
        Merchant(name: "Trattoria Da Enzo", bookedName: "Trattoria Da Enzo", cents: 2_400...8_800, purpose: "Restaurant"),
        Merchant(name: "Sushi Circle", bookedName: "Sushi Circle Ehrenfeld", cents: 1_800...6_400, purpose: "Restaurant"),
        Merchant(name: "IKEA", bookedName: "IKEA Deutschland GmbH", cents: 1_299...24_900, purpose: "Einrichtung"),
        Merchant(name: "MediaMarkt", bookedName: "MediaMarkt Köln-Kalk", cents: 1_499...39_900, purpose: "Elektronik"),
        Merchant(name: "Kino Odeon", bookedName: "Kino Odeon Lichtspiele", cents: 1_100...3_200, purpose: "Kino"),
    ]

    static let online: [Merchant] = [
        Merchant(name: "AMAZON", bookedName: "AMAZON EU S.A R.L.", cents: 899...14_900, purpose: "Bestellung"),
        Merchant(name: "ZALANDO", bookedName: "ZALANDO SE", cents: 2_995...18_900, purpose: "Bestellung"),
        Merchant(name: "Lieferando", bookedName: "Lieferando.de", cents: 1_890...4_800, purpose: "Bestellung"),
        Merchant(name: "Apple.com/bill", bookedName: "Apple.com/bill ITUNES.COM", cents: 99...2_999, purpose: "App Store"),
        Merchant(name: "Uber", bookedName: "Uber BV Trip", cents: 900...4_200, purpose: "Fahrt"),
        Merchant(name: "Booking.com", bookedName: "Booking.com Amsterdam", cents: 8_900...48_000, purpose: "Hotel"),
    ]

    /// Foreign-currency merchants: amount in USD cents, booked in EUR.
    static let foreign: [Merchant] = [
        Merchant(name: "Steam Purchase", bookedName: "Steam Purchase Bellevue", cents: 499...5_999, purpose: "USD"),
        Merchant(name: "Airbnb", bookedName: "Airbnb Payments San Francisco", cents: 9_900...64_000, purpose: "USD"),
        Merchant(name: "Github", bookedName: "Github Inc San Francisco", cents: 400...2_100, purpose: "USD"),
    ]

    // MARK: - Make

    mutating func make() -> MockDataset {
        generateING()
        generateDKB()
        generateTradeRepublic()
        generateC24()
        generateEasybank()
        generatePayPal()
        generateSparkasse()
        let dkbStatements = settleCard(MockAccounts.dkbVisa, closingDay: 22, dueAfterDays: 5, payer: MockAccounts.dkbGiro, payerName: "DKB AG", creditorID: nil)
        let easyStatements = settleCard(MockAccounts.easyVisa, closingDay: 7, dueAfterDays: 13, payer: MockAccounts.ingGiro, payerName: "easybank AG", creditorID: "DE00ZZZ00000000001")

        var current: [AccountID: [Transaction]] = [:]
        var afterBooking: [AccountID: [Transaction]] = [:]
        for account in Self.accounts {
            let list = (transactions[account.id] ?? []).sorted { $0.effectiveDate > $1.effectiveDate }
            current[account.id] = Transaction.uniquingIDs(list)
            afterBooking[account.id] = Transaction.uniquingIDs(list.map(bookPending))
        }

        return MockDataset(
            today: today,
            now: now,
            connections: Self.connections,
            accounts: Self.accounts,
            transactions: current,
            transactionsAfterBooking: afterBooking,
            cardStatements: [MockAccounts.dkbVisa: dkbStatements, MockAccounts.easyVisa: easyStatements],
            securities: makeSecurities(),
            openingBalances: Self.openingBalances,
            overdraftCents: Self.overdrafts
        )
    }

    // MARK: - Banks

    private mutating func generateING() {
        let giro = MockAccounts.ingGiro
        monthly(day: 27) { me, day in
            me.add(giro, day, me.vary(512_257, by: 4_000), "Muster Technik GmbH", "LOHN/GEHALT \(String(format: "%02d", day.month))/\(day.year)", iban: "DE00 3704 0044 0000 0000 10", eref: "LG\(day.year)\(day.month)")
        }
        monthly(day: 1, plannedAhead: 31) { me, day in
            me.add(giro, day, -115_000, "Hausverwaltung Sommer", "Miete Wohnung 3. OG links", iban: "DE00 3705 0198 0000 0000 11", status: day > me.today ? .planned : .booked)
        }
        monthly(day: 15) { me, day in
            me.add(giro, day, -me.vary(8_400, by: 600), "Stadtwerke Köln GmbH", "Abschlag Strom/Gas Vertragskonto 4711", iban: "DE00 3705 0198 0000 0000 12", mref: "SWK-4711-01", creditorID: "DE00ZZZ00000000002")
        }
        monthly(day: 5) { me, day in
            me.add(giro, day, -3_995, "Telekom Deutschland GmbH", "Festnetz/Internet Kundennr. 123456789", iban: "DE00 7007 0010 0000 0000 13", mref: "TDG-0001", creditorID: "DE00ZZZ00000000003")
        }
        monthly(day: 10) { me, day in
            me.add(giro, day, -2_499, "Vodafone GmbH", "Mobilfunk Rechnung", iban: "DE00 3004 0000 0000 0000 14", mref: "VF-778", creditorID: "DE00ZZZ00000000004")
        }
        monthly(day: 12) { me, day in
            me.add(giro, day, -1_399, "PayPal Europe S.a.r.l.", "Netflix International B.V.", iban: "DE00 1203 0000 0000 0000 15", mref: "PP-NFLX", creditorID: "DE00ZZZ00000000005")
        }
        monthly(day: 3) { me, day in
            me.add(giro, day, -1_199, "PayPal Europe S.a.r.l.", "Spotify AB", iban: "DE00 1203 0000 0000 0000 15", mref: "PP-SPOT", creditorID: "DE00ZZZ00000000005")
        }
        monthly(day: 28) { me, day in
            me.add(giro, day, -30_000, "Eigenes Extra-Konto", "Sparen", iban: "DE00 5001 0517 0000 0000 02")
            me.add(MockAccounts.ingExtra, day, 30_000, "Eigenes Girokonto", "Sparen", iban: "DE00 5001 0517 0000 0000 01")
        }
        monthly(day: 2) { me, day in
            me.add(giro, day, -50_000, "Trade Republic Bank GmbH", "Einzahlung", iban: "DE00 1001 0000 0000 0000 04")
            me.add(MockAccounts.trCash, day, 50_000, "Eigenes ING Girokonto", "Einzahlung", iban: "DE00 5001 0517 0000 0000 01")
        }
        monthly(day: 20) { me, day in
            me.add(giro, day, -150_000, "Eigenes DKB Girokonto", "Umbuchung Haushalt", iban: "DE00 1203 0000 0000 0000 03")
            me.add(MockAccounts.dkbGiro, day, 150_000, "Eigenes ING Girokonto", "Umbuchung Haushalt", iban: "DE00 5001 0517 0000 0000 01")
        }
        quarterly(day: 15) { me, day in
            me.add(giro, day, -5_508, "Rundfunk ARD, ZDF, DRadio", "Rundfunkbeitrag Beitragsnr. 000000000", iban: "DE00 7005 0000 0000 0000 16", mref: "RB-000", creditorID: "DE00ZZZ00000000006")
            me.add(giro, day.adding(days: 1), -8_940, "HUK-COBURG", "Kfz-Versicherung Vers.-Nr. 000/000", iban: "DE00 7835 0000 0000 0000 17", mref: "HUK-1", creditorID: "DE00ZZZ00000000007")
        }
        monthly(day: 30) { me, day in
            me.add(MockAccounts.ingExtra, day, me.vary(1_840, by: 300), "ING", "Zinsen", iban: nil)
        }
        randomSpending(giro, perMonth: 14, merchants: Self.groceries + Self.everyday, purposePrefix: "Kartenzahlung girocard")
        randomEvents(giro, perMonth: 1) { me, day in
            me.add(giro, day, -me.pick([5_000, 10_000, 20_000]), "Geldautomat Sparkasse", "Bargeldauszahlung", iban: nil)
        }
        recentPending(giro, count: 2, merchants: Self.groceries, purposePrefix: "Kartenzahlung girocard")
    }

    private mutating func generateDKB() {
        let giro = MockAccounts.dkbGiro
        let visa = MockAccounts.dkbVisa
        monthly(day: 1) { me, day in
            me.add(giro, day, -4_900, "Urban Sports GmbH", "Mitgliedschaft", iban: "DE00 1001 0010 0000 0000 18", mref: "USC-42", creditorID: "DE00ZZZ00000000008")
        }
        randomSpending(giro, perMonth: 9, merchants: Self.groceries, purposePrefix: "Kartenzahlung Visa Debit")
        randomSpending(visa, perMonth: 11, merchants: Self.online + Self.everyday, purposePrefix: "VISA")
        randomForeign(visa, perMonth: 2)
        recentPending(visa, count: 3, merchants: Self.online, purposePrefix: "VISA")
        cancelled(visa, merchant: Self.online[5], daysAgo: 40)
        monthly(day: 6) { me, day in
            // Dividend / interest credit on the card account is rare; keep the giro lively instead.
            me.add(giro, day, me.vary(1_250, by: 400), "Erstattung Krankenkasse", "Erstattung Rechnung", iban: "DE00 3705 0000 0000 0000 19")
        }
    }

    private mutating func generateTradeRepublic() {
        let cash = MockAccounts.trCash
        monthly(day: 3) { me, day in
            me.add(cash, day, -25_000, "Sparplan", "Sparplan iShares Core MSCI World", iban: nil)
        }
        monthly(day: 4) { me, day in
            me.add(cash, day, -5_000, "Sparplan", "Sparplan Vanguard FTSE All-World", iban: nil)
        }
        monthly(day: 1) { me, day in
            me.add(cash, day, me.vary(310, by: 80), "Trade Republic", "Zinsen", iban: nil)
        }
        randomSpending(cash, perMonth: 3, merchants: Self.everyday + Self.online, purposePrefix: "Kartentransaktion")
        recentPending(cash, count: 1, merchants: Self.everyday, purposePrefix: "Kartentransaktion")
    }

    private mutating func generateC24() {
        let giro = MockAccounts.c24Giro
        monthly(day: 26) { me, day in
            me.add(giro, day, 45_000, "Eigenes ING Girokonto", "Taschengeld Konto", iban: "DE00 5001 0517 0000 0000 01")
        }
        monthly(day: 27) { me, day in
            me.add(giro, day, -10_000, "Pocket Urlaub", "Pocket Umbuchung", iban: nil)
            me.add(MockAccounts.c24Pocket, day, 10_000, "Smartkonto", "Pocket Umbuchung", iban: nil)
        }
        quarterly(day: 10) { me, day in
            me.add(MockAccounts.c24Pocket, day, -me.vary(12_000, by: 6_000), "Smartkonto", "Pocket Auszahlung", iban: nil)
        }
        randomSpending(giro, perMonth: 6, merchants: Self.groceries + Self.everyday, purposePrefix: "Mastercard")
        recentPending(giro, count: 1, merchants: Self.groceries, purposePrefix: "Mastercard")
    }

    /// A small PayPal balance: money from a friend now and then, a few purchases paid from it.
    private mutating func generatePayPal() {
        monthly(day: 9) { me, day in
            me.add(MockAccounts.paypal, day, 2_500, "Lena Beispiel", "Geld erhalten", iban: nil)
        }
        monthly(day: 14) { me, day in
            me.add(MockAccounts.paypal, day, -me.vary(1_800, by: 600), "Buchhandlung Lesezeichen", "Zahlung", iban: nil)
        }
    }

    /// The bank over YAXI: a small everyday account fed from the ING account, rent and utilities, a few
    /// card payments, and a Tagesgeld with interest. Generated last, so the other banks keep their data.
    private mutating func generateSparkasse() {
        let giro = MockAccounts.sparkasseGiro
        monthly(day: 21) { me, day in
            me.add(MockAccounts.ingGiro, day, -38_000, "Eigenes Sparkasse Girokonto", "Umbuchung Miete und Alltag", iban: "DE00 3705 0198 0000 0000 07")
            me.add(giro, day, 38_000, "Eigenes ING Girokonto", "Umbuchung Miete und Alltag", iban: "DE00 5001 0517 0000 0000 01")
        }
        monthly(day: 3) { me, day in
            me.add(giro, day, -28_000, "Hausverwaltung Beispiel GmbH", "Miete Zimmer Musterweg 1", iban: "DE00 3705 0198 0000 0000 21", mref: "MIETE-1", creditorID: "DE00ZZZ00000000009")
        }
        monthly(day: 8) { me, day in
            me.add(giro, day, -4_000, "Stadtwerke Musterstadt", "Strom und Wasser Abschlag", iban: "DE00 3705 0198 0000 0000 22", mref: "SW-17", creditorID: "DE00ZZZ00000000010")
        }
        monthly(day: 30) { me, day in
            me.add(MockAccounts.sparkasseTagesgeld, day, me.vary(1_300, by: 200), "Sparkasse", "Zinsen", iban: nil)
        }
        randomSpending(giro, perMonth: 2, merchants: Self.groceries + Self.everyday, purposePrefix: "Kartenzahlung girocard")
        recentPending(giro, count: 1, merchants: Self.groceries, purposePrefix: "Kartenzahlung girocard")
    }

    private mutating func generateEasybank() {
        monthly(day: 31) { me, day in
            me.add(MockAccounts.easyTagesgeld, day, me.vary(2_900, by: 200), "easybank AG", "Habenzinsen", iban: nil)
        }
        randomSpending(MockAccounts.easyVisa, perMonth: 6, merchants: Self.online + Self.groceries, purposePrefix: "Kartenumsatz")
        randomForeign(MockAccounts.easyVisa, perMonth: 1)
        recentPending(MockAccounts.easyVisa, count: 2, merchants: Self.online, purposePrefix: "Kartenumsatz")
        cancelled(MockAccounts.easyVisa, merchant: Self.everyday[6], daysAgo: 75)
    }

    // MARK: - Card settlement

    /// Builds statements for every closed period and books the settlement on card and payer.
    /// Must run after all purchases of the card are generated (statements sum purchases only).
    private mutating func settleCard(_ card: AccountID, closingDay: Int, dueAfterDays: Int, payer: AccountID, payerName: String, creditorID: String?) -> [CardStatement] {
        let purchases = (transactions[card] ?? []).filter { $0.status == .booked }
        var statements: [CardStatement] = []
        var periodEnd = Self.day(in: firstDay, day: closingDay)
        while periodEnd < firstDay { periodEnd = periodEnd.adding(months: 1) }

        while periodEnd < today {
            let periodStart = periodEnd.adding(months: -1).adding(days: 1)
            let total = purchases.filter { $0.effectiveDate >= periodStart && $0.effectiveDate <= periodEnd }.reduce(0) { $0 + $1.amountCents }
            let due = periodEnd.adding(days: dueAfterDays)
            statements.append(CardStatement(accountID: card, periodStart: periodStart, periodEnd: periodEnd, dueDate: due, amountCents: total))
            if due <= today, total != 0 {
                let label = "Kreditkartenabrechnung \(periodEnd.iso)"
                add(card, due, -total, "Ausgleich Abrechnung", label, iban: nil)
                add(payer, due, total, payerName, label, iban: nil, mref: creditorID.map { _ in "KK-\(card.rawValue)" }, creditorID: creditorID)
            }
            periodEnd = Self.day(in: periodEnd.adding(months: 1), day: closingDay)
        }
        return statements.sorted { $0.periodEnd > $1.periodEnd }
    }

    // MARK: - Securities

    private func makeSecurities() -> [AccountID: [SecurityPosition]] {
        func position(_ account: AccountID, _ isin: String, _ name: String, _ quantity: String, _ price: Int, purchase: Int? = nil) -> SecurityPosition {
            SecurityPosition(accountID: account, isin: isin, name: name, quantity: Decimal(string: quantity, locale: Locale(identifier: "en_US_POSIX")) ?? 0, priceCents: price, asOf: now, purchasePriceCents: purchase)
        }
        return [
            MockAccounts.dkbDepot: [
                position(MockAccounts.dkbDepot, "IE00B4L5Y983", "iShares Core MSCI World UCITS ETF", "142", 10_987, purchase: 7_854),
                position(MockAccounts.dkbDepot, "IE00BKM4GZ66", "iShares Core MSCI EM IMI UCITS ETF", "310", 3_412, purchase: 3_590),
            ],
            MockAccounts.trDepot: [
                position(MockAccounts.trDepot, "IE00B4L5Y983", "iShares Core MSCI World UCITS ETF", "48.312574", 10_987),
                position(MockAccounts.trDepot, "IE00BK5BQT80", "Vanguard FTSE All-World UCITS ETF", "21.904411", 13_655),
                position(MockAccounts.trDepot, "US0378331005", "Apple Inc.", "3.5", 21_480),
                position(MockAccounts.trDepot, "DE0007164600", "SAP SE", "4", 24_315),
            ],
        ]
    }

    // MARK: - Pending → booked

    private func bookPending(_ transaction: Transaction) -> Transaction {
        guard transaction.status == .pending else { return transaction }
        let merchant = (Self.groceries + Self.everyday + Self.online).first { $0.name == transaction.counterpartName }
        return Transaction(
            accountID: transaction.accountID,
            bookingDate: transaction.valueDate.adding(days: 2),
            valueDate: transaction.valueDate,
            amountCents: transaction.amountCents,
            currency: transaction.currency,
            counterpartName: merchant?.bookedName ?? transaction.counterpartName,
            purpose: transaction.purpose + " Buchung",
            status: .booked,
            rawJSON: transaction.rawJSON
        )
    }

    // MARK: - Building blocks

    private mutating func add(
        _ account: AccountID,
        _ day: BankDay,
        _ cents: Int,
        _ counterpart: String,
        _ purpose: String,
        iban: String?,
        eref: String? = nil,
        mref: String? = nil,
        creditorID: String? = nil,
        status: TransactionStatus = .booked,
        originalCents: Int? = nil,
        originalCurrency: String? = nil
    ) {
        guard day >= firstDay else { return }
        sequence += 1
        let raw = Data("{\"mock\":true,\"seq\":\(sequence)}".utf8)
        let booking: BankDay? = (status == .booked || status == .cancelled) ? day : nil
        transactions[account, default: []].append(Transaction(
            accountID: account,
            bookingDate: booking,
            valueDate: day,
            amountCents: cents,
            counterpartName: counterpart,
            counterpartIBAN: iban,
            purpose: purpose,
            eref: eref,
            mref: mref,
            creditorID: creditorID,
            status: status,
            originalAmountCents: originalCents,
            originalCurrency: originalCurrency,
            rawJSON: raw
        ))
    }

    /// Calls `body` on `day` of every month in the history; `plannedAhead` also emits future
    /// occurrences within that many days (as planned transactions).
    private mutating func monthly(day: Int, plannedAhead: Int = 0, _ body: (inout MockGenerator, BankDay) -> Void) {
        every(months: 1, day: day, plannedAhead: plannedAhead, body)
    }

    private mutating func quarterly(day: Int, _ body: (inout MockGenerator, BankDay) -> Void) {
        every(months: 3, day: day, plannedAhead: 0, body)
    }

    private mutating func every(months step: Int, day: Int, plannedAhead: Int, _ body: (inout MockGenerator, BankDay) -> Void) {
        let horizon = today.adding(days: plannedAhead)
        var month = firstDay
        while true {
            let occurrence = Self.businessDay(Self.day(in: month, day: day))
            if occurrence > horizon { break }
            if occurrence >= firstDay, occurrence <= today || plannedAhead > 0 {
                body(&self, occurrence)
            }
            month = month.adding(months: step)
        }
    }

    private mutating func randomEvents(_ account: AccountID, perMonth: Int, _ body: (inout MockGenerator, BankDay) -> Void) {
        let span = firstDay.days(to: today.adding(days: -3))
        let count = perMonth * Self.historyMonths
        for _ in 0..<count {
            body(&self, firstDay.adding(days: rng.int(0...span)))
        }
    }

    private mutating func randomSpending(_ account: AccountID, perMonth: Int, merchants: [Merchant], purposePrefix: String) {
        randomEvents(account, perMonth: perMonth) { me, day in
            let merchant = me.rng.pick(merchants)
            let cents = me.rng.int(merchant.cents)
            me.add(account, day, -cents, merchant.bookedName, "\(purposePrefix) \(merchant.purpose)", iban: nil)
        }
    }

    private mutating func randomForeign(_ account: AccountID, perMonth: Int) {
        randomEvents(account, perMonth: perMonth) { me, day in
            let merchant = me.rng.pick(Self.foreign)
            let usd = me.rng.int(merchant.cents)
            let eur = Int((Double(usd) * 0.92).rounded())
            me.add(account, day, -eur, merchant.bookedName, "VISA \(merchant.name) USD \(Self.formatCents(usd)) Kurs 1,0870", iban: nil, originalCents: -usd, originalCurrency: "USD")
        }
    }

    private mutating func recentPending(_ account: AccountID, count: Int, merchants: [Merchant], purposePrefix: String) {
        for index in 0..<count {
            let merchant = rng.pick(merchants)
            let cents = rng.int(merchant.cents)
            add(account, today.adding(days: -(index % 3)), -cents, merchant.name, "\(purposePrefix) \(merchant.purpose)", iban: nil, status: .pending)
        }
    }

    private mutating func cancelled(_ account: AccountID, merchant: Merchant, daysAgo: Int) {
        add(account, today.adding(days: -daysAgo), -rng.int(merchant.cents), merchant.bookedName, "STORNO \(merchant.purpose)", iban: nil, status: .cancelled)
    }

    private mutating func vary(_ cents: Int, by spread: Int) -> Int {
        cents + rng.int(-spread...spread)
    }

    private mutating func pick<T>(_ items: [T]) -> T {
        rng.pick(items)
    }

    // MARK: - Dates

    /// `day` within the month of `reference`, clamped to the month's last day.
    static func day(in reference: BankDay, day: Int) -> BankDay {
        var candidate = min(day, 31)
        while candidate > 28 {
            if let valid = BankDay(year: reference.year, month: reference.month, day: candidate) { return valid }
            candidate -= 1
        }
        return BankDay(year: reference.year, month: reference.month, day: candidate) ?? reference
    }

    /// Moves Saturday/Sunday bookings to the following Monday, as banks do.
    static func businessDay(_ day: BankDay) -> BankDay {
        switch day.weekday {
        case 7: day.adding(days: 2)
        case 1: day.adding(days: 1)
        default: day
        }
    }

    static func formatCents(_ cents: Int) -> String {
        String(format: "%d,%02d", cents / 100, cents % 100)
    }
}
