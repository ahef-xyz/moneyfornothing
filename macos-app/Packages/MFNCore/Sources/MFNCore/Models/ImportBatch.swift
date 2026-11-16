import Foundation

/// One CSV import into one account (protocol v10). Rows it added carry its `id` in
/// `Transaction.importID`; rows from a bank sync have `importID == nil`.
///
/// `fileName` is the name of the imported file. It stays in the local, encrypted database and is
/// never logged.
public struct ImportBatch: Identifiable, Hashable, Codable, Sendable {
    public let id: ImportBatchID
    public let accountID: AccountID
    public let importedAt: Date
    /// `CSVPreset.id` of the detected layout; `nil` = generic detection.
    public let format: String?
    public let fileName: String?
    /// `CSVEncoding.rawValue` of the file; `nil` if unknown (batches backfilled by the migration).
    public let encoding: String?
    /// Rows the import added (rows removed later are not subtracted).
    public let rowCount: Int

    public init(id: ImportBatchID = .make(), accountID: AccountID, importedAt: Date = Date(), format: String?,
                fileName: String?, encoding: String?, rowCount: Int) {
        self.id = id
        self.accountID = accountID
        self.importedAt = importedAt
        self.format = format
        self.fileName = fileName
        self.encoding = encoding
        self.rowCount = rowCount
    }

    /// Name of the detected layout ("ING", "MoneyForNothing-Export"), `nil` for generic detection.
    public var formatName: String? {
        guard let format else { return nil }
        return CSVPreset.all.first { $0.id == format }?.name ?? format
    }

    /// The same import on another account (connection merge).
    public func moved(to account: AccountID) -> ImportBatch {
        ImportBatch(id: id, accountID: account, importedAt: importedAt, format: format, fileName: fileName,
                    encoding: encoding, rowCount: rowCount)
    }

    /// The synthetic batch the v10 migration creates for rows imported before batches existed.
    public static func backfillID(for account: AccountID) -> ImportBatchID {
        ImportBatchID("backfill:\(account.rawValue)")
    }
}

/// Removing transactions is only allowed for imported rows: synced bank data is never deleted.
public enum TransactionRemovalError: Error, Equatable, Sendable {
    /// These IDs are bank data (no `importID`); nothing was removed.
    case notImported(Set<TransactionID>)
}

extension Transaction {
    /// The category the imported file gave this row (MFN's own export: `Kategorie-ID`, else
    /// `Kategorie`), read from `rawJSON`. `nil` for bank rows and files without a category.
    /// Decodes JSON: for one row (inspector), not for lists.
    public var categoryFromImportFile: CategoryID? {
        guard importID != nil,
              let object = try? JSONSerialization.jsonObject(with: rawJSON) as? [String: Any],
              let row = object["row"] as? [String: String] else { return nil }
        func cell(_ field: CSVField) -> String? {
            let wanted = Set(field.aliases.map(CSVLayout.key))
            return row.first { wanted.contains(CSVLayout.key($0.key)) }?.value.trimmingCharacters(in: .whitespaces)
                .nilIfEmpty
        }
        return CSVDocument.category(id: cell(.categoryID), name: cell(.categoryName))
    }

    /// The category still is the one the import brought (manual, same as in the file); a
    /// correction by the user or a machine suggestion is not.
    public var categoryCameFromImport: Bool {
        guard importID != nil, categorySource == .manual, let categoryID else { return false }
        return categoryFromImportFile == categoryID
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
