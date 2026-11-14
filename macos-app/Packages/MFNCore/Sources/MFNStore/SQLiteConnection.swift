import Foundation
import MFNSQLCipherKey
import SQLCipher

/// A value bound to or read from SQLite.
enum SQLValue: Equatable, Sendable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    init(_ value: Int?) { self = value.map { .integer(Int64($0)) } ?? .null }
    init(_ value: Double?) { self = value.map { .real($0) } ?? .null }
    init(_ value: String?) { self = value.map { .text($0) } ?? .null }
    init(_ value: Data?) { self = value.map { .blob($0) } ?? .null }
    init(_ value: Date?) { self = value.map { .real($0.timeIntervalSince1970) } ?? .null }
}

struct SQLiteError: Error, Equatable, Sendable, CustomStringConvertible {
    let code: Int32
    let message: String

    var description: String { "SQLite \(code): \(message)" }

    /// `SQLITE_NOTADB`: wrong key, or not a database.
    var isNotADatabase: Bool { code & 0xFF == SQLITE_NOTADB }
}

/// One row of a result, addressed by column name.
struct SQLRow {
    private let values: [String: SQLValue]

    init(_ values: [String: SQLValue]) { self.values = values }

    func value(_ column: String) -> SQLValue { values[column] ?? .null }

    func int(_ column: String) throws -> Int {
        guard case let .integer(value) = value(column) else { throw StoreError.corruptRow("\(column) is not an integer") }
        return Int(value)
    }

    func optionalInt(_ column: String) throws -> Int? {
        if case .null = value(column) { return nil }
        return try int(column)
    }

    func double(_ column: String) throws -> Double {
        switch value(column) {
        case let .real(value): return value
        case let .integer(value): return Double(value)
        default: throw StoreError.corruptRow("\(column) is not a number")
        }
    }

    func optionalDouble(_ column: String) throws -> Double? {
        if case .null = value(column) { return nil }
        return try double(column)
    }

    func string(_ column: String) throws -> String {
        guard case let .text(value) = value(column) else { throw StoreError.corruptRow("\(column) is not text") }
        return value
    }

    func optionalString(_ column: String) throws -> String? {
        if case .null = value(column) { return nil }
        return try string(column)
    }

    func data(_ column: String) throws -> Data {
        guard case let .blob(value) = value(column) else { throw StoreError.corruptRow("\(column) is not a blob") }
        return value
    }

    func date(_ column: String) throws -> Date {
        Date(timeIntervalSince1970: try double(column))
    }

    func optionalDate(_ column: String) throws -> Date? {
        try optionalDouble(column).map(Date.init(timeIntervalSince1970:))
    }
}

/// Minimal SQLCipher connection. Not thread-safe by design: exactly one owner (an actor).
final class SQLiteConnection {
    private var handle: OpaquePointer?
    private var statementCache: [String: OpaquePointer] = [:]

    /// Opens (or creates) the database and applies the key before anything else touches the file.
    init(path: String, passphrase: Data) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let openResult = sqlite3_open_v2(path, &db, flags, nil)
        handle = db
        guard openResult == SQLITE_OK else {
            let error = Self.error(db, openResult)
            sqlite3_close_v2(db)
            handle = nil
            throw error
        }
        let keyResult = passphrase.withUnsafeBytes { buffer in
            mfn_sqlcipher_key(db, buffer.baseAddress, Int32(buffer.count))
        }
        guard keyResult == SQLITE_OK else {
            let error = Self.error(db, keyResult)
            close()
            throw error
        }
    }

    deinit {
        close()
    }

    func close() {
        guard let handle else { return }
        for statement in statementCache.values {
            sqlite3_finalize(statement)
        }
        statementCache = [:]
        sqlite3_close_v2(handle)
        self.handle = nil
    }

    var isOpen: Bool { handle != nil }

    /// Runs one or more statements without parameters (schema, pragmas).
    func execute(_ sql: String) throws {
        let db = try requireHandle()
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &message)
        guard result == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(message)
            throw SQLiteError(code: result, message: text)
        }
    }

    /// Runs a statement with parameters, discarding results.
    func run(_ sql: String, _ arguments: [SQLValue] = []) throws {
        try withStatement(sql, arguments) { statement in
            while try step(statement) {}
        }
    }

    /// Runs a query and returns all rows.
    func query(_ sql: String, _ arguments: [SQLValue] = []) throws -> [SQLRow] {
        try withStatement(sql, arguments) { statement in
            var rows: [SQLRow] = []
            let count = sqlite3_column_count(statement)
            let names = (0..<count).map { String(cString: sqlite3_column_name(statement, $0)) }
            while try step(statement) {
                var values: [String: SQLValue] = [:]
                for index in 0..<count {
                    values[names[Int(index)]] = column(statement, index)
                }
                rows.append(SQLRow(values))
            }
            return rows
        }
    }

    /// Runs `body` in a transaction; rolls back if it throws.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK") // Rollback failure is secondary; the original error is rethrown.
            throw error
        }
    }

    /// Number of rows changed by the last statement.
    var changes: Int {
        handle.map { Int(sqlite3_changes($0)) } ?? 0
    }

    // MARK: - Internals

    private func requireHandle() throws -> OpaquePointer {
        guard let handle else { throw StoreError.closed }
        return handle
    }

    private func withStatement<T>(_ sql: String, _ arguments: [SQLValue], _ body: (OpaquePointer) throws -> T) throws -> T {
        let db = try requireHandle()
        let statement: OpaquePointer
        if let cached = statementCache[sql] {
            statement = cached
        } else {
            var prepared: OpaquePointer?
            let result = sqlite3_prepare_v2(db, sql, -1, &prepared, nil)
            guard result == SQLITE_OK, let prepared else { throw Self.error(db, result) }
            statementCache[sql] = prepared
            statement = prepared
        }
        defer {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }
        try bind(arguments, to: statement, db: db)
        return try body(statement)
    }

    private func bind(_ arguments: [SQLValue], to statement: OpaquePointer, db: OpaquePointer) throws {
        let expected = Int(sqlite3_bind_parameter_count(statement))
        guard expected == arguments.count else {
            throw SQLiteError(code: SQLITE_RANGE, message: "expected \(expected) arguments, got \(arguments.count)")
        }
        for (offset, value) in arguments.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32 = switch value {
            case .null: sqlite3_bind_null(statement, index)
            case let .integer(int): sqlite3_bind_int64(statement, index, int)
            case let .real(double): sqlite3_bind_double(statement, index, double)
            case let .text(text): sqlite3_bind_text(statement, index, text, -1, Self.transient)
            case let .blob(data): data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), Self.transient) }
            }
            guard result == SQLITE_OK else { throw Self.error(db, result) }
        }
    }

    /// `true` while rows are available, `false` when done.
    private func step(_ statement: OpaquePointer) throws -> Bool {
        let result = sqlite3_step(statement)
        switch result {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw Self.error(handle, result)
        }
    }

    private func column(_ statement: OpaquePointer, _ index: Int32) -> SQLValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT:
            return .real(sqlite3_column_double(statement, index))
        case SQLITE_TEXT:
            guard let text = sqlite3_column_text(statement, index) else { return .null }
            return .text(String(cString: text))
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, index))
            guard count > 0, let bytes = sqlite3_column_blob(statement, index) else { return .blob(Data()) }
            return .blob(Data(bytes: bytes, count: count))
        default:
            return .null
        }
    }

    /// `SQLITE_TRANSIENT`: SQLite copies the bound buffer before the call returns.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func error(_ db: OpaquePointer?, _ code: Int32) -> SQLiteError {
        let message = db.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? String(cString: sqlite3_errstr(code))
        return SQLiteError(code: code, message: message)
    }
}
