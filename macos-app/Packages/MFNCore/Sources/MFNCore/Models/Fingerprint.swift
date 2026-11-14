import CryptoKit
import Foundation

/// Stable identity of a transaction across syncs and import paths (FinTS, scraping, CSV).
///
/// `SHA-256( accountID | bookingDate | amountCents | normalizedPurpose | counterpartIBAN )`
///
/// - `bookingDate` is `yyyy-MM-dd`, or empty for pending/planned transactions.
/// - `normalizedPurpose`: see `normalize(purpose:)`.
/// - `counterpartIBAN`: upper-cased without spaces, or empty.
///
/// Changing this function changes every stored fingerprint: it is part of the frozen protocol.
public enum Fingerprint {
    public static func make(
        accountID: AccountID,
        bookingDate: BankDay?,
        amountCents: Int,
        purpose: String,
        counterpartIBAN: String?
    ) -> String {
        let fields = [
            accountID.rawValue,
            bookingDate?.iso ?? "",
            String(amountCents),
            normalize(purpose: purpose),
            normalize(iban: counterpartIBAN),
        ]
        let digest = SHA256.hash(data: Data(fields.joined(separator: "|").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Case-, diacritic- and whitespace-insensitive purpose text.
    ///
    /// FinTS (MT940 wraps at 27 characters, sometimes mid-word), camt, web JSON and CSV export
    /// deliver the same purpose with different wrapping and spacing. Removing all whitespace
    /// and folding case/diacritics removes exactly those differences.
    public static func normalize(purpose: String) -> String {
        purpose
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "de_DE"))
            .filter { !$0.isWhitespace }
    }

    public static func normalize(iban: String?) -> String {
        guard let iban else { return "" }
        return iban.filter { !$0.isWhitespace }.uppercased()
    }
}
