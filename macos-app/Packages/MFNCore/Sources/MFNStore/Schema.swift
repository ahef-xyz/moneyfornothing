import Foundation
import MFNCore

/// Database schema. Explicit SQL columns so Phase 3 tools can aggregate in SQL: bank days as
/// `yyyy-MM-dd` text, amounts as integer cents, instants as Unix seconds (REAL).
///
/// Migrations are numbered by `PRAGMA user_version`. Never edit a shipped migration; append one.
enum Schema {
    static let migrations: [String] = [
        // 1 – initial schema
        """
        CREATE TABLE connection (
            id TEXT PRIMARY KEY NOT NULL,
            connectorID TEXT NOT NULL,
            displayName TEXT NOT NULL
        );
        CREATE TABLE account (
            id TEXT PRIMARY KEY NOT NULL,
            connectionID TEXT NOT NULL REFERENCES connection(id) ON DELETE CASCADE,
            iban TEXT,
            type TEXT NOT NULL,
            currency TEXT NOT NULL,
            name TEXT NOT NULL,
            cardLast4 TEXT,
            creditLimitCents INTEGER,
            position INTEGER NOT NULL
        );
        CREATE TABLE balance (
            accountID TEXT PRIMARY KEY NOT NULL REFERENCES account(id) ON DELETE CASCADE,
            bookedCents INTEGER NOT NULL,
            availableCents INTEGER,
            currency TEXT NOT NULL,
            asOf REAL NOT NULL
        );
        CREATE TABLE ledgerTransaction (
            id TEXT PRIMARY KEY NOT NULL,
            accountID TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
            bookingDate TEXT,
            valueDate TEXT NOT NULL,
            amountCents INTEGER NOT NULL,
            currency TEXT NOT NULL,
            counterpartName TEXT NOT NULL,
            counterpartIBAN TEXT,
            purpose TEXT NOT NULL,
            eref TEXT,
            mref TEXT,
            creditorID TEXT,
            status TEXT NOT NULL,
            externalID TEXT,
            fingerprint TEXT NOT NULL,
            originalAmountCents INTEGER,
            originalCurrency TEXT,
            rawJSON BLOB NOT NULL,
            categoryID TEXT,
            categorySource TEXT,
            confidence REAL
        );
        CREATE INDEX ledgerTransaction_account_date ON ledgerTransaction(accountID, valueDate);
        CREATE INDEX ledgerTransaction_fingerprint ON ledgerTransaction(fingerprint);
        CREATE TABLE cardStatement (
            accountID TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
            periodStart TEXT NOT NULL,
            periodEnd TEXT NOT NULL,
            dueDate TEXT,
            amountCents INTEGER NOT NULL,
            currency TEXT NOT NULL,
            pdfBlobID TEXT,
            PRIMARY KEY (accountID, periodEnd)
        );
        CREATE TABLE securityPosition (
            accountID TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
            isin TEXT NOT NULL,
            name TEXT NOT NULL,
            quantity TEXT NOT NULL,
            priceCents INTEGER NOT NULL,
            currency TEXT NOT NULL,
            asOf REAL NOT NULL,
            PRIMARY KEY (accountID, isin)
        );
        CREATE TABLE syncState (
            connectionID TEXT PRIMARY KEY NOT NULL REFERENCES connection(id) ON DELETE CASCADE,
            phase TEXT NOT NULL,
            lastSuccess REAL,
            consecutiveFailures INTEGER NOT NULL
        );
        """,
        // 2 – names the user gave accounts (the bank's name stays in `account.name`)
        """
        CREATE TABLE accountName (
            accountID TEXT PRIMARY KEY NOT NULL REFERENCES account(id) ON DELETE CASCADE,
            name TEXT NOT NULL
        );
        """,
        // 3 – category rules (match as JSON of `CategoryRule.Match`)
        """
        CREATE TABLE categoryRule (
            id TEXT PRIMARY KEY NOT NULL,
            match TEXT NOT NULL,
            categoryID TEXT NOT NULL,
            createdAt REAL NOT NULL
        );
        """,
        // 4 – spending budgets per account
        """
        CREATE TABLE budget (
            accountID TEXT PRIMARY KEY NOT NULL REFERENCES account(id) ON DELETE CASCADE,
            amountCents INTEGER NOT NULL,
            period TEXT NOT NULL,
            startDay INTEGER NOT NULL
        );
        """,
        // 5 – budget period anchored to incoming money (both NULL = fixed start day)
        """
        ALTER TABLE budget ADD COLUMN anchorTolerance INTEGER;
        ALTER TABLE budget ADD COLUMN anchorCounterpart TEXT;
        """,
        // 6 – average purchase price per unit (protocol v9), NULL if the bank sends none
        """
        ALTER TABLE securityPosition ADD COLUMN purchasePriceCents INTEGER;
        """,
        // 7 – depot value per day (recorded with every depot sync, last one of a day wins)
        """
        CREATE TABLE depotValue (
            accountID TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
            day TEXT NOT NULL,
            valueCents INTEGER NOT NULL,
            purchaseCents INTEGER,
            currency TEXT NOT NULL,
            PRIMARY KEY (accountID, day)
        );
        """,
        // 8 – one-off payments the user plans (forecast only; `ignoredMatches` = JSON array of
        // transaction IDs)
        """
        CREATE TABLE plannedItem (
            id TEXT PRIMARY KEY NOT NULL,
            accountID TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
            day TEXT NOT NULL,
            amountCents INTEGER NOT NULL,
            title TEXT NOT NULL,
            createdAt REAL NOT NULL,
            ignoredMatches TEXT NOT NULL
        );
        """,
        // 9 – opening balance of accounts without a bank connection (protocol v10,
        // `ConnectorID.manual`); `day` NULL = every booking counts.
        """
        CREATE TABLE openingBalance (
            accountID TEXT PRIMARY KEY NOT NULL REFERENCES account(id) ON DELETE CASCADE,
            cents INTEGER NOT NULL,
            day TEXT
        );
        """,
        // 10 – CSV imports (`importBatchMigration`)
        importBatchMigration,
        // 11 – transactions a sync brought in that the user has not looked at yet
        // (`LedgerSnapshot.newTransactionIDs`); they go with their row.
        """
        CREATE TABLE newTransaction (
            id TEXT PRIMARY KEY NOT NULL REFERENCES ledgerTransaction(id) ON DELETE CASCADE
        );
        """,
    ]

    /// 10 – CSV imports (protocol v10): `importBatch` plus `ledgerTransaction.importID` (NULL = bank
    /// sync). Backfill: rows a CSV import wrote before (`rawJSON` `{"format":…,"row":{…},"source":"csv"}`)
    /// get one synthetic batch per account (`ImportBatch.backfillID`, format if all rows agree,
    /// importedAt = migration time, no file name or encoding).
    /// Kept as one self-contained step, so it can be renumbered when branches merge.
    static let importBatchMigration = """
        CREATE TABLE importBatch (
            id TEXT PRIMARY KEY NOT NULL,
            accountID TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
            importedAt REAL NOT NULL,
            format TEXT,
            fileName TEXT,
            encoding TEXT,
            rowCount INTEGER NOT NULL
        );
        CREATE INDEX importBatch_account ON importBatch(accountID);
        ALTER TABLE ledgerTransaction ADD COLUMN importID TEXT;
        CREATE INDEX ledgerTransaction_import ON ledgerTransaction(importID);
        CREATE TEMP TABLE csvBackfill AS
            SELECT id, accountID, json_extract(raw, '$.format') AS format
            FROM (SELECT id, accountID, CAST(rawJSON AS TEXT) AS raw FROM ledgerTransaction)
            WHERE CASE WHEN json_valid(raw)
                THEN json_type(raw) = 'object' AND json_extract(raw, '$.source') = 'csv' AND json_type(raw, '$.row') = 'object'
                ELSE 0 END;
        INSERT INTO importBatch (id, accountID, importedAt, format, fileName, encoding, rowCount)
            SELECT 'backfill:' || accountID, accountID, CAST(strftime('%s', 'now') AS REAL),
                   CASE WHEN COUNT(DISTINCT format) = 1 AND COUNT(format) = COUNT(*) THEN MAX(format) END,
                   NULL, NULL, COUNT(*)
            FROM csvBackfill GROUP BY accountID;
        UPDATE ledgerTransaction SET importID = 'backfill:' || accountID WHERE id IN (SELECT id FROM csvBackfill);
        DROP TABLE csvBackfill;
        """

    static func migrate(_ db: SQLiteConnection) throws {
        let current = try db.query("PRAGMA user_version").first?.int("user_version") ?? 0
        guard current <= migrations.count else {
            throw StoreError.newerSchema(found: current, supported: migrations.count)
        }
        for (index, sql) in migrations.enumerated() where index >= current {
            try db.transaction {
                try db.execute(sql)
                try db.execute("PRAGMA user_version = \(index + 1)")
            }
        }
    }
}

// MARK: - Mapping

private let positionLocale = Locale(identifier: "en_US_POSIX")

private func day(_ row: SQLRow, _ column: String) throws -> BankDay {
    let text = try row.string(column)
    guard let day = BankDay(iso: text) else { throw StoreError.corruptRow(column) }
    return day
}

private func optionalDay(_ row: SQLRow, _ column: String) throws -> BankDay? {
    guard try row.optionalString(column) != nil else { return nil }
    return try day(row, column)
}

private func enumValue<T: RawRepresentable>(_ row: SQLRow, _ column: String) throws -> T where T.RawValue == String {
    let text = try row.string(column)
    guard let value = T(rawValue: text) else { throw StoreError.corruptRow(column) }
    return value
}

private func optionalEnumValue<T: RawRepresentable>(_ row: SQLRow, _ column: String) throws -> T? where T.RawValue == String {
    guard try row.optionalString(column) != nil else { return nil }
    return try enumValue(row, column) as T
}

/// `INSERT … ON CONFLICT DO UPDATE`. Never `INSERT OR REPLACE`: replace deletes the row first
/// and would cascade-delete children (accounts of a connection, transactions of an account).
func upsertSQL(table: String, columns: [String], conflict: [String]) -> String {
    let placeholders = Array(repeating: "?", count: columns.count).joined(separator: ", ")
    let updates = columns.filter { !conflict.contains($0) }.map { "\($0) = excluded.\($0)" }.joined(separator: ", ")
    let action = updates.isEmpty ? "NOTHING" : "UPDATE SET \(updates)"
    return "INSERT INTO \(table) (\(columns.joined(separator: ", "))) VALUES (\(placeholders)) ON CONFLICT(\(conflict.joined(separator: ", "))) DO \(action)"
}

enum ConnectionTable {
    static let columns = ["id", "connectorID", "displayName"]
    static let upsert = upsertSQL(table: "connection", columns: columns, conflict: ["id"])

    static func values(_ c: Connection) -> [SQLValue] {
        [.text(c.id.rawValue), .text(c.connectorID.rawValue), .text(c.displayName)]
    }

    static func model(_ row: SQLRow) throws -> Connection {
        Connection(id: ConnectionID(try row.string("id")), connectorID: try enumValue(row, "connectorID"), displayName: try row.string("displayName"))
    }
}

enum AccountTable {
    static let columns = ["id", "connectionID", "iban", "type", "currency", "name", "cardLast4", "creditLimitCents", "position"]
    static let upsert = upsertSQL(table: "account", columns: columns, conflict: ["id"])

    static func values(_ a: Account, position: Int) -> [SQLValue] {
        [.text(a.id.rawValue), .text(a.connectionID.rawValue), SQLValue(a.iban), .text(a.type.rawValue), .text(a.currency),
         .text(a.name), SQLValue(a.cardLast4), SQLValue(a.creditLimitCents), SQLValue(position)]
    }

    static func model(_ row: SQLRow) throws -> Account {
        Account(
            id: AccountID(try row.string("id")),
            connectionID: ConnectionID(try row.string("connectionID")),
            iban: try row.optionalString("iban"),
            type: try enumValue(row, "type"),
            currency: try row.string("currency"),
            name: try row.string("name"),
            cardLast4: try row.optionalString("cardLast4"),
            creditLimitCents: try row.optionalInt("creditLimitCents")
        )
    }
}

enum BalanceTable {
    static let columns = ["accountID", "bookedCents", "availableCents", "currency", "asOf"]
    static let upsert = upsertSQL(table: "balance", columns: columns, conflict: ["accountID"])

    static func values(_ b: Balance, account: AccountID) -> [SQLValue] {
        [.text(account.rawValue), SQLValue(b.bookedCents), SQLValue(b.availableCents), .text(b.currency), SQLValue(b.asOf)]
    }

    static func model(_ row: SQLRow) throws -> (AccountID, Balance) {
        (AccountID(try row.string("accountID")),
         Balance(bookedCents: try row.int("bookedCents"), availableCents: try row.optionalInt("availableCents"), currency: try row.string("currency"), asOf: try row.date("asOf")))
    }
}

enum TransactionTable {
    static let columns = ["id", "accountID", "bookingDate", "valueDate", "amountCents", "currency", "counterpartName",
                          "counterpartIBAN", "purpose", "eref", "mref", "creditorID", "status", "externalID", "fingerprint",
                          "originalAmountCents", "originalCurrency", "rawJSON", "categoryID", "categorySource", "confidence", "importID"]
    static let upsert = upsertSQL(table: "ledgerTransaction", columns: columns, conflict: ["id"])

    static func values(_ t: Transaction) -> [SQLValue] {
        [.text(t.id.rawValue), .text(t.accountID.rawValue), SQLValue(t.bookingDate?.iso), .text(t.valueDate.iso),
         SQLValue(t.amountCents), .text(t.currency), .text(t.counterpartName), SQLValue(t.counterpartIBAN), .text(t.purpose),
         SQLValue(t.eref), SQLValue(t.mref), SQLValue(t.creditorID), .text(t.status.rawValue), SQLValue(t.externalID),
         .text(t.fingerprint), SQLValue(t.originalAmountCents), SQLValue(t.originalCurrency), .blob(t.rawJSON),
         SQLValue(t.categoryID?.rawValue), SQLValue(t.categorySource?.rawValue), SQLValue(t.confidence),
         SQLValue(t.importID?.rawValue)]
    }

    static func model(_ row: SQLRow) throws -> Transaction {
        let id = try row.string("id")
        let transaction = Transaction(
            id: TransactionID(id),
            accountID: AccountID(try row.string("accountID")),
            bookingDate: try optionalDay(row, "bookingDate"),
            valueDate: try day(row, "valueDate"),
            amountCents: try row.int("amountCents"),
            currency: try row.string("currency"),
            counterpartName: try row.string("counterpartName"),
            counterpartIBAN: try row.optionalString("counterpartIBAN"),
            purpose: try row.string("purpose"),
            eref: try row.optionalString("eref"),
            mref: try row.optionalString("mref"),
            creditorID: try row.optionalString("creditorID"),
            status: try enumValue(row, "status"),
            externalID: try row.optionalString("externalID"),
            originalAmountCents: try row.optionalInt("originalAmountCents"),
            originalCurrency: try row.optionalString("originalCurrency"),
            rawJSON: try row.data("rawJSON"),
            categoryID: try row.optionalString("categoryID").map(CategoryID.init(rawValue:)),
            categorySource: try optionalEnumValue(row, "categorySource"),
            confidence: try row.optionalDouble("confidence"),
            importID: try row.optionalString("importID").map(ImportBatchID.init(rawValue:))
        )
        // The fingerprint is recomputed from the fields; a mismatch means the row was altered
        // or the fingerprint rule changed without a migration. Not worth locking the whole
        // database over: the recomputed one is used (and written with the next change of the row).
        if transaction.fingerprint != (try row.string("fingerprint")) {
            Log.store.error("Fingerprint einer Buchung weicht ab, wird neu berechnet: \(id, privacy: .private)")
        }
        return transaction
    }
}

enum ImportBatchTable {
    static let columns = ["id", "accountID", "importedAt", "format", "fileName", "encoding", "rowCount"]
    static let upsert = upsertSQL(table: "importBatch", columns: columns, conflict: ["id"])

    static func values(_ b: ImportBatch) -> [SQLValue] {
        [.text(b.id.rawValue), .text(b.accountID.rawValue), SQLValue(b.importedAt), SQLValue(b.format),
         SQLValue(b.fileName), SQLValue(b.encoding), SQLValue(b.rowCount)]
    }

    static func model(_ row: SQLRow) throws -> ImportBatch {
        ImportBatch(id: ImportBatchID(try row.string("id")), accountID: AccountID(try row.string("accountID")),
                    importedAt: try row.date("importedAt"), format: try row.optionalString("format"),
                    fileName: try row.optionalString("fileName"), encoding: try row.optionalString("encoding"),
                    rowCount: try row.int("rowCount"))
    }
}

enum CardStatementTable {
    static let columns = ["accountID", "periodStart", "periodEnd", "dueDate", "amountCents", "currency", "pdfBlobID"]
    static let insert = "INSERT INTO cardStatement (\(columns.joined(separator: ", "))) VALUES (\(Array(repeating: "?", count: columns.count).joined(separator: ", ")))"

    static func values(_ s: CardStatement) -> [SQLValue] {
        [.text(s.accountID.rawValue), .text(s.periodStart.iso), .text(s.periodEnd.iso), SQLValue(s.dueDate?.iso),
         SQLValue(s.amountCents), .text(s.currency), SQLValue(s.pdfBlobID)]
    }

    static func model(_ row: SQLRow) throws -> CardStatement {
        CardStatement(
            accountID: AccountID(try row.string("accountID")),
            periodStart: try day(row, "periodStart"),
            periodEnd: try day(row, "periodEnd"),
            dueDate: try optionalDay(row, "dueDate"),
            amountCents: try row.int("amountCents"),
            currency: try row.string("currency"),
            pdfBlobID: try row.optionalString("pdfBlobID")
        )
    }
}

enum SecurityPositionTable {
    static let columns = ["accountID", "isin", "name", "quantity", "priceCents", "currency", "asOf", "purchasePriceCents"]
    static let insert = "INSERT INTO securityPosition (\(columns.joined(separator: ", "))) VALUES (\(Array(repeating: "?", count: columns.count).joined(separator: ", ")))"

    static func values(_ p: SecurityPosition) -> [SQLValue] {
        // Decimal as exact text: no binary floating point for share counts.
        [.text(p.accountID.rawValue), .text(p.isin), .text(p.name), .text(NSDecimalNumber(decimal: p.quantity).description(withLocale: positionLocale)),
         SQLValue(p.priceCents), .text(p.currency), SQLValue(p.asOf), SQLValue(p.purchasePriceCents)]
    }

    static func model(_ row: SQLRow) throws -> SecurityPosition {
        let quantityText = try row.string("quantity")
        guard let quantity = Decimal(string: quantityText, locale: positionLocale) else { throw StoreError.corruptRow("quantity") }
        return SecurityPosition(
            accountID: AccountID(try row.string("accountID")),
            isin: try row.string("isin"),
            name: try row.string("name"),
            quantity: quantity,
            priceCents: try row.int("priceCents"),
            currency: try row.string("currency"),
            asOf: try row.date("asOf"),
            purchasePriceCents: try row.optionalInt("purchasePriceCents")
        )
    }
}

enum DepotValueTable {
    static let columns = ["accountID", "day", "valueCents", "purchaseCents", "currency"]
    static let upsert = upsertSQL(table: "depotValue", columns: columns, conflict: ["accountID", "day"])

    static func values(_ p: DepotValuePoint) -> [SQLValue] {
        [.text(p.accountID.rawValue), .text(p.day.iso), SQLValue(p.valueCents), SQLValue(p.purchaseCents), .text(p.currency)]
    }

    static func model(_ row: SQLRow) throws -> DepotValuePoint {
        DepotValuePoint(accountID: AccountID(try row.string("accountID")), day: try day(row, "day"),
                        valueCents: try row.int("valueCents"), purchaseCents: try row.optionalInt("purchaseCents"),
                        currency: try row.string("currency"))
    }
}

enum PlannedItemTable {
    static let columns = ["id", "accountID", "day", "amountCents", "title", "createdAt", "ignoredMatches"]
    static let upsert = upsertSQL(table: "plannedItem", columns: columns, conflict: ["id"])

    static func values(_ item: PlannedItem) throws -> [SQLValue] {
        let ignored = String(decoding: try JSONEncoder().encode(item.ignoredMatches.map(\.rawValue).sorted()), as: UTF8.self)
        return [.text(item.id.uuidString), .text(item.accountID.rawValue), .text(item.day.iso), SQLValue(item.amountCents),
                .text(item.title), .real(item.createdAt.timeIntervalSince1970), .text(ignored)]
    }

    static func model(_ row: SQLRow) throws -> PlannedItem {
        guard let id = UUID(uuidString: try row.string("id")),
              let ignored = try? JSONDecoder().decode([String].self, from: Data(try row.string("ignoredMatches").utf8)) else {
            throw StoreError.corruptRow("plannedItem")
        }
        return PlannedItem(id: id, accountID: AccountID(try row.string("accountID")), day: try day(row, "day"),
                           amountCents: try row.int("amountCents"), title: try row.string("title"),
                           createdAt: Date(timeIntervalSince1970: try row.double("createdAt")),
                           ignoredMatches: Set(ignored.map(TransactionID.init(rawValue:))))
    }
}

enum OpeningBalanceTable {
    static let columns = ["accountID", "cents", "day"]
    static let upsert = upsertSQL(table: "openingBalance", columns: columns, conflict: ["accountID"])

    static func values(_ opening: OpeningBalance, account: AccountID) -> [SQLValue] {
        [.text(account.rawValue), SQLValue(opening.cents), opening.day.map { .text($0.iso) } ?? .null]
    }

    static func model(_ row: SQLRow) throws -> (AccountID, OpeningBalance) {
        (AccountID(try row.string("accountID")), OpeningBalance(cents: try row.int("cents"), day: try optionalDay(row, "day")))
    }
}

enum SyncStateTable {
    static let columns = ["connectionID", "phase", "lastSuccess", "consecutiveFailures"]
    static let upsert = upsertSQL(table: "syncState", columns: columns, conflict: ["connectionID"])

    static func values(_ s: SyncState, connection: ConnectionID) throws -> [SQLValue] {
        let phase = String(decoding: try JSONEncoder().encode(s.phase), as: UTF8.self)
        return [.text(connection.rawValue), .text(phase), SQLValue(s.lastSuccess), SQLValue(s.consecutiveFailures)]
    }

    /// A sync that was running or waiting for approval when the app quit is not running anymore.
    static func model(_ row: SQLRow) throws -> (ConnectionID, SyncState) {
        let stored: SyncState.Phase
        do {
            stored = try JSONDecoder().decode(SyncState.Phase.self, from: Data(try row.string("phase").utf8))
        } catch {
            throw StoreError.corruptRow("syncState.phase")
        }
        let phase: SyncState.Phase = switch stored {
        case .syncing, .waitingForApproval: .idle
        default: stored
        }
        return (ConnectionID(try row.string("connectionID")),
                SyncState(phase: phase, lastSuccess: try row.optionalDate("lastSuccess"), consecutiveFailures: try row.int("consecutiveFailures")))
    }
}
