import Foundation
import FoundationModels
import MFNCore
import Testing
@testable import MFNIntelligence

private func tx(_ id: String, _ name: String, _ purpose: String, cents: Int = -1_000, category: CategoryID? = nil, account: AccountID = "a1") -> Transaction {
    let day = BankDay(year: 2026, month: 11, day: 9)! // a Monday
    return Transaction(id: TransactionID(id), accountID: account, bookingDate: day, valueDate: day, amountCents: cents,
                       counterpartName: name, purpose: purpose, status: .booked,
                       categoryID: category, categorySource: category == nil ? nil : .manual)
}

@Suite struct TransactionTextTests {
    @Test func keepsOnlyTheSVWZPartOfTaggedPurposes() {
        let text = TransactionText.cleanPurpose("EREF+AB12CD34EF56GH MREF+M12345XYZ CRED+DE98ZZZ09999999999 SVWZ+Abschlag Strom 11/2026 Vertragskonto 4711081500")
        #expect(text == "Abschlag Strom Vertragskonto")
    }

    @Test func dropsCardReferencesDatesAndTimes() {
        let text = TransactionText.cleanPurpose("VISA Debitkartenumsatz 03.06. 18:28 Karte 1 Folgenr. 20")
        #expect(!text.contains("18:28"))
        #expect(!text.contains("03.06."))
        #expect(text.hasPrefix("VISA Debitkartenumsatz"))
    }

    @Test func dropsLabeledReferencesAndIBANs() {
        let text = TransactionText.cleanPurpose("Miete November End-to-End-Ref.: 2026110812345 IBAN DE02120300000000202051")
        #expect(text == "Miete November")
    }

    @Test func purposeIsCappedAt120Characters() {
        let long = String(repeating: "Wort ", count: 60)
        #expect(TransactionText.cleanPurpose(long).count <= TransactionText.maxPurposeLength)
    }

    @Test func merchantLosesCityLegalFormAndStoreNumber() {
        #expect(TransactionText.cleanMerchant("REWE Markt GmbH//Berlin/DE") == "REWE Markt")
        #expect(TransactionText.cleanMerchant("ARAL Station 28041234") == "ARAL Station")
    }
}

@Suite struct LLMContractTests {
    @Test func generableEnumMirrorsTheCatalogOneToOne() {
        #expect(LLMCategory.allCases.map(\.rawValue) == CategoryCatalog.all.map(\.id.rawValue))
    }

    @Test func instructionsStayBelow300Tokens() async throws {
        // Conservative estimate without the model: German text runs ~3.5 characters per token.
        #expect(Double(LLMPrompt.instructions.count) / 3.0 < 300)
        if #available(macOS 26.4, *), case .available = SystemLanguageModelProbe.availability {
            let tokens = try await SystemLanguageModelProbe.tokenCount(LLMPrompt.instructions)
            #expect(tokens < 300)
        }
    }

    @Test func promptCarriesOnlyMerchantPurposeAmountWeekdayAccount() {
        let t = Transaction(accountID: "a1", bookingDate: BankDay(year: 2026, month: 11, day: 9)!, valueDate: BankDay(year: 2026, month: 11, day: 9)!,
                            amountCents: -4_299, counterpartName: "Stadtwerke Musterstadt", counterpartIBAN: "DE02120300000000202051",
                            purpose: "EREF+X1Y2Z3A4B5C6 MREF+M998877 CRED+DE98ZZZ09999999999 SVWZ+Abschlag Strom", eref: "X1Y2Z3A4B5C6",
                            mref: "M998877", creditorID: "DE98ZZZ09999999999", status: .booked)
        let line = LLMPrompt.describe(t, accountType: .giro)
        #expect(line == "Händler: Stadtwerke Musterstadt; Zweck: Abschlag Strom; Betrag: -42,99 €; Tag: Montag; Konto: Girokonto")
        #expect(!line.contains("DE02"))
        #expect(!line.contains("ZZZ"))
    }

    @Test func implausibleIncomeCategoryIsCappedForReview() {
        let expense = tx("t1", "Muster GmbH", "Zahlung", cents: -5_000)
        let items = [LLMPrompt.Item(number: 1, transaction: expense, accountType: .giro)]
        let answer = LLMBatchAnswer(zuordnungen: [LLMAssignment(nummer: 1, kategorie: .gehalt, sicherheit: 95)])
        let s = LLMStage.suggestions(from: answer, items: items, maxConfidence: 0.9)
        #expect(s[expense.id]?.categoryID == "gehalt")
        #expect((s[expense.id]?.confidence ?? 1) < Categorizer.reviewThreshold)
    }

    @Test func modelConfidenceIsBoundedAndUnknownNumbersIgnored() {
        let expense = tx("t1", "REWE", "Einkauf")
        let items = [LLMPrompt.Item(number: 1, transaction: expense, accountType: .giro)]
        let answer = LLMBatchAnswer(zuordnungen: [
            LLMAssignment(nummer: 1, kategorie: .lebensmittel, sicherheit: 100),
            LLMAssignment(nummer: 7, kategorie: .miete, sicherheit: 100),
        ])
        let s = LLMStage.suggestions(from: answer, items: items, maxConfidence: 0.9)
        #expect(s.count == 1)
        #expect(s[expense.id]?.confidence == 0.9)
        #expect(s[expense.id]?.source == .llm)
    }

    @Test func unavailableModelYieldsNothing() async {
        let stage = LLMStage()
        guard !stage.isAvailable else { return }
        let result = await stage.suggest([tx("t1", "REWE", "Einkauf")], context: CategorizationContext())
        #expect(result.isEmpty)
    }
}

@Suite struct KNNStageTests {
    private let history = [
        tx("h1", "REWE Markt GmbH//Berlin/DE", "VISA Debitkartenumsatz 01.11. 10:12", category: "lebensmittel"),
        tx("h2", "REWE Markt GmbH//Hamburg/DE", "VISA Debitkartenumsatz 03.11. 18:40", category: "lebensmittel"),
        tx("h3", "Stadtwerke Musterstadt", "EREF+AAAA1111BBBB SVWZ+Abschlag Strom 10/2026", category: "nebenkosten"),
        tx("h4", "Netflix International B.V.", "Netflix Monatsabo", category: "abos"),
        tx("h5", "AMAZON PAYMENTS EUROPE S.C.A.", "302-1234567 AMZN Mktp DE", category: "online_shopping"),
        tx("h6", "AMAZON PAYMENTS EUROPE S.C.A.", "Erstattung Bestellung 302-7654321", cents: 2_500, category: "erstattung"),
    ]

    @Test func nearDuplicateIsTakenOverDirectly() async {
        let stage = KNNStage(embedding: HybridEmbedding(useSentenceModel: false))
        let query = tx("q1", "REWE Markt GmbH//Koeln/DE", "VISA Debitkartenumsatz 07.11. 09:01")
        let s = await stage.suggest([query], context: CategorizationContext(labeled: history))
        #expect(s[query.id]?.categoryID == "lebensmittel")
        #expect((s[query.id]?.confidence ?? 0) >= 0.9)
        #expect(s[query.id]?.source == .knn)
    }

    @Test func signSeparatesRefundFromPurchase() async {
        let stage = KNNStage(embedding: HybridEmbedding(useSentenceModel: false))
        let refund = tx("q2", "AMAZON PAYMENTS EUROPE S.C.A.", "Erstattung Bestellung 302-1112223", cents: 1_999)
        let s = await stage.suggest([refund], context: CategorizationContext(labeled: history))
        #expect(s[refund.id]?.categoryID == "erstattung")
    }

    @Test func farAwayBookingIsNotConfident() async {
        let stage = KNNStage(embedding: HybridEmbedding(useSentenceModel: false))
        let query = tx("q3", "Schluesseldienst Schnell", "Notoeffnung Wohnungstuer")
        let s = await stage.suggest([query], context: CategorizationContext(labeled: history))
        #expect((s[query.id]?.confidence ?? 0) < 0.85)
    }

    @Test func noModelMeansNoSuggestions() async {
        struct NoModel: TextEmbedding {
            func vectors(for texts: [TransactionText]) async -> [TransactionText: [Float]]? { nil }
        }
        let stage = KNNStage(embedding: NoModel())
        let s = await stage.suggest([tx("q1", "REWE", "Einkauf")], context: CategorizationContext(labeled: history))
        #expect(s.isEmpty)
    }

    @Test func sentenceEmbeddingIsCachedAndStable() async {
        let embedding = HybridEmbedding()
        let text = TransactionText(merchant: "Stadtwerke Musterstadt", purpose: "Abschlag Strom")
        let a = await embedding.vectors(for: [text])?[text]
        let b = await embedding.vectors(for: [text])?[text]
        #expect(a != nil)
        #expect(a == b)
        if let a { #expect(abs(VectorMath.dot(a, a) - 1) < 1e-3) }
    }
}

/// Access to the real model for token counts (only when it is available on this Mac).
enum SystemLanguageModelProbe {
    static var availability: SystemLanguageModel.Availability { SystemLanguageModel(useCase: .contentTagging).availability }

    @available(macOS 26.4, *)
    static func tokenCount(_ text: String) async throws -> Int {
        try await SystemLanguageModel(useCase: .contentTagging).tokenCount(for: Instructions(text))
    }
}
