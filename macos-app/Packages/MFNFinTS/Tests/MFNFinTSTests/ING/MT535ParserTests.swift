import Foundation
import MFNConformance
import MFNCore
import Testing
@testable import MFNFinTS

/// Synthetic MT535 (statement of holdings) – invented positions, real ISIN format.
enum SyntheticMT535 {
    static let depot = """
    :16R:GENL
    :28E:1/ONLY
    :20C::SEME//NONREF
    :23G:NEWM
    :98C::PREP//20261109120000
    :98A::STAT//20261109
    :22F::STTY//CUST
    :97A::SAFE//50010517/0000000000
    :17B::ACTI//Y
    :16S:GENL
    :16R:FIN
    :35B:ISIN IE00B4L5Y983/DE/A0RPWH
    ISHSIII-CORE MSCI WORLD U.ETF
    REGISTERED SHS USD (ACC) O.N.
    :90B::MRKT//ACTU/EUR98,765
    :94B::PRIC//LMAR/XETR
    :98A::PRIC//20261106
    :93B::AGGR//UNIT/12,5
    :16R:SUBBAL
    :93C::TAVI//UNIT/AVAI/12,5
    :16S:SUBBAL
    :19A::HOLD//EUR1234,56
    :70E::HOLD//1STK
    285,123456+EUR
    :16S:FIN
    :16R:FIN
    :35B:ISIN DE0001102580/DE/110258
    BUNDESREP.DEUTSCHLAND ANL.V.2022
    :90A::MRKT//PRCT/101,5
    :98A::PRIC//20261105
    :93B::AGGR//FAMT/10000,
    :19A::HOLD//EUR10150,
    :70E::HOLD//1FAMT
    299,25+EUR
    :16S:FIN
    :16R:FIN
    :35B:/DE/999999
    OHNE ISIN
    :93B::AGGR//UNIT/1,
    :16S:FIN
    :16R:ADDINFO
    :19A::HOLP//EUR11384,56
    :16S:ADDINFO
    """
}

@Suite struct MT535ParserTests {
    @Test func parsesHoldings() throws {
        let statement = try MT535Parser.parse(SyntheticMT940.data(SyntheticMT535.depot))
        #expect(statement.statementDate == BankDay(year: 2026, month: 11, day: 9))
        #expect(statement.holdings.count == 3)
        #expect(statement.totalValueCents == 1_138_456)

        let etf = statement.holdings[0]
        #expect(etf.isin == "IE00B4L5Y983")
        #expect(etf.nationalID == "A0RPWH")
        #expect(etf.name == "ISHSIII-CORE MSCI WORLD U.ETF REGISTERED SHS USD (ACC) O.N.")
        #expect(etf.quantity == Decimal(string: "12.5"))
        #expect(!etf.quantityIsFaceAmount)
        #expect(etf.price == Decimal(string: "98.765"))
        #expect(etf.priceCurrency == "EUR")
        #expect(etf.priceDate == BankDay(year: 2026, month: 11, day: 6))
        #expect(etf.holdingValueCents == 123_456)
        #expect(etf.purchasePrice == Decimal(string: "85.123456"))
        #expect(etf.purchaseCurrency == "EUR")

        let bond = statement.holdings[1]
        #expect(bond.quantityIsFaceAmount)
        #expect(bond.priceIsPercentage)
        #expect(bond.quantity == 10000)
        #expect(bond.price == Decimal(string: "101.5"))
        #expect(bond.purchasePrice == Decimal(string: "99.25"))

        #expect(statement.holdings[2].purchasePrice == nil)

        #expect(statement.holdings[2].isin == nil)
        #expect(statement.holdings[2].nationalID == "999999")
    }

    @Test func mapsToSecurityPositions() throws {
        let statement = try MT535Parser.parse(SyntheticMT535.depot)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let positions = INGMapping.positions(statement, accountID: "depot", currency: "EUR", now: now)
        // The holding without ISIN is skipped.
        #expect(positions.map(\.isin) == ["IE00B4L5Y983", "DE0001102580"])
        #expect(positions[0].priceCents == 9876) // 9876,5 rounds half-even
        #expect(positions[0].quantity == Decimal(string: "12.5"))
        #expect(positions[0].asOf == BankDay(year: 2026, month: 11, day: 6)!.startDate)
        // Bond: per 100 face value, value stays exact.
        #expect(positions[1].quantity == 100)
        #expect(positions[1].priceCents == 10150)
        #expect(positions[1].valueCents == 1_015_000)
        #expect(positions.allSatisfy { $0.accountID == "depot" && $0.currency == "EUR" })
        // Purchase price in the same unit as the price.
        #expect(positions[0].purchasePriceCents == 8512)
        #expect(positions[0].purchaseValueCents == 106_400) // 12,5 × 85,12
        #expect(positions[0].gainCents == 123_450 - 106_400)
        #expect(positions[1].purchasePriceCents == 9925)
        #expect(positions[1].gainCents == 1_015_000 - 992_500)
    }

    @Test func nationalIDOnItsOwnLine() throws {
        // Invented security (not a real holding), only the layout is ING's.
        let text = ":16R:FIN\n:35B:ISIN XS0000000001\n/DE/ABC123\nBEISPIEL FONDS D\n:93B::AGGR//UNIT/3,\n:16S:FIN"
        let holding = try #require(try MT535Parser.parse(text).holdings.first)
        #expect(holding.isin == "XS0000000001")
        #expect(holding.nationalID == "ABC123")
        #expect(holding.name == "BEISPIEL FONDS D")
    }

    @Test func purchasePriceLayouts() {
        #expect(MT535Parser.purchasePrice("1STK\n2123,456789+EUR")?.price == Decimal(string: "123.456789"))
        #expect(MT535Parser.purchasePrice("1STK\n2123,4+EUR")?.currency == "EUR")
        #expect(MT535Parser.purchasePrice("1STK\n212,5")?.currency == nil)
        // Only the unit line, or a zero price: no purchase price.
        #expect(MT535Parser.purchasePrice("1STK") == nil)
        #expect(MT535Parser.purchasePrice("1STK\n20,+EUR") == nil)
    }

    @Test func bondWithoutPercentPriceHasNoPurchasePrice() throws {
        // FAMT priced by holding value, not PRCT: the per-100-face purchase price would not fit
        // the quantity (face amount), so it is dropped instead of a gain 100 times too large.
        let text = ":16R:FIN\n:35B:ISIN XS0000000002\nANLEIHE\n:93B::AGGR//FAMT/10000,\n:19A::HOLD//EUR10150,\n:70E::HOLD//1FAMT\n299,25+EUR\n:16S:FIN"
        let positions = INGMapping.positions(try MT535Parser.parse(text), accountID: "depot", currency: "EUR", now: .now)
        #expect(positions.first?.purchasePriceCents == nil)
        #expect(positions.first?.gainCents == nil)
    }

    @Test func bondPurchasePriceInAnotherCurrencyIsDropped() throws {
        let text = SyntheticMT535.depot.replacingOccurrences(of: "299,25+EUR", with: "299,25+USD")
        let positions = INGMapping.positions(try MT535Parser.parse(text), accountID: "depot", currency: "EUR", now: .now)
        #expect(positions[1].purchasePriceCents == nil)
    }

    @Test func absurdPurchasePriceIsRejected() {
        #expect(MT535Parser.purchasePrice("1STK\n299999999999999999999,+EUR") == nil)
    }

    @Test func purchasePriceInAnotherCurrencyIsDropped() throws {
        let text = SyntheticMT535.depot.replacingOccurrences(of: "285,123456+EUR", with: "285,123456+USD")
        let positions = INGMapping.positions(try MT535Parser.parse(text), accountID: "depot", currency: "EUR", now: .now)
        #expect(positions[0].purchasePriceCents == nil)
        #expect(positions[0].gainCents == nil)
    }

    @Test func missingQuantityIsAFormatError() {
        #expect(throws: MT940Error.self) {
            try MT535Parser.parse(":16R:FIN\n:35B:ISIN DE0001102580\nX\n:16S:FIN")
        }
    }

    @Test func realFixtureParsesIfPresent() throws {
        guard Fixtures.exists(.ing, "mt535-depot.sta") else { return }
        let statement = try MT535Parser.parse(Fixtures.data(.ing, "mt535-depot.sta"))
        #expect(!statement.holdings.isEmpty)
    }
}
