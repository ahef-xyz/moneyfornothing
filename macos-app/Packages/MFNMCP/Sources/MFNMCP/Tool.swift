import Foundation
import MFNCore

/// A tool call's answer: the structured result and how many rows or values it carries (for the
/// activity log, never the content).
struct ToolOutput {
    var result: JSONValue
    var count: Int
}

/// A wrong argument; goes back to the client as a tool error it can correct.
struct ToolError: Error, Equatable {
    var message: String
    init(_ message: String) { self.message = message }
}

/// One read-only tool.
struct MCPTool: Sendable {
    let name: String
    let title: String
    let description: String
    let inputSchema: JSONValue
    let run: @Sendable (Arguments, ScopedLedger) throws -> ToolOutput

    var definition: JSONValue {
        [
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": inputSchema,
            "annotations": [
                "title": .string(title),
                "readOnlyHint": true,
                "destructiveHint": false,
                "idempotentHint": true,
                "openWorldHint": false,
            ],
        ]
    }
}

/// Typed access to a call's arguments with errors the model can act on.
struct Arguments {
    let values: [String: JSONValue]

    init(_ value: JSONValue?) {
        values = value?.objectValue ?? [:]
    }

    func string(_ key: String) throws(ToolError) -> String? {
        guard let value = values[key], value != .null else { return nil }
        guard let text = value.stringValue else { throw ToolError("'\(key)' must be a string") }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func bool(_ key: String, default fallback: Bool) throws(ToolError) -> Bool {
        guard let value = values[key], value != .null else { return fallback }
        guard let flag = value.boolValue else { throw ToolError("'\(key)' must be true or false") }
        return flag
    }

    func int(_ key: String, default fallback: Int, range: ClosedRange<Int>) throws(ToolError) -> Int {
        guard let value = values[key], value != .null else { return fallback }
        guard let number = value.intValue, range.contains(number) else {
            throw ToolError("'\(key)' must be a whole number from \(range.lowerBound) to \(range.upperBound)")
        }
        return number
    }

    func day(_ key: String) throws(ToolError) -> BankDay? {
        guard let text = try string(key) else { return nil }
        guard let day = BankDay(iso: text) else { throw ToolError("'\(key)' must be a date like 2026-11-24") }
        return day
    }

    func cents(_ key: String) throws(ToolError) -> Int? {
        guard let value = values[key], value != .null else { return nil }
        guard let cents = Money.cents(value) else { throw ToolError("'\(key)' must be an amount like \"12.50\" (at most 2 decimals)") }
        return cents
    }

    /// `from`/`to` (or with a prefix). Missing ends: the month of the given end, else the
    /// current month; a missing `to` after a `from` runs to the end of the current month.
    func period(_ prefix: String = "", in ledger: ScopedLedger, required: Bool = false, maxMonths: Int? = nil) throws(ToolError) -> DayPeriod {
        let fromKey = prefix + "from", toKey = prefix + "to"
        let from = try day(fromKey), to = try day(toKey)
        if required, from == nil || to == nil { throw ToolError("'\(fromKey)' and '\(toKey)' are required") }
        let anchor = DayPeriod.month(of: to ?? from ?? ledger.today)
        let current = DayPeriod.month(of: ledger.today)
        let end = to ?? (from.map { max(DayPeriod.month(of: $0).to, current.to) } ?? anchor.to)
        guard let period = DayPeriod(from: from ?? anchor.from, to: end) else {
            throw ToolError("'\(fromKey)' must not be after '\(toKey)'")
        }
        if let maxMonths, period.months.count > maxMonths {
            throw ToolError("The period spans more than \(maxMonths) months. Choose a shorter one.")
        }
        return period
    }

    func account(_ key: String = "account_id", in ledger: ScopedLedger) throws(ToolError) -> Account? {
        guard let opaque = try string(key) else { return nil }
        guard let account = ledger.accountsByOpaqueID[opaque] else {
            throw ToolError("Unknown '\(key)'. Use an id from list_accounts.")
        }
        return account
    }

    func direction() throws(ToolError) -> Aggregations.Direction? {
        guard let text = try string("direction") else { return nil }
        guard let direction = Aggregations.Direction(rawValue: text) else { throw ToolError("'direction' must be 'income' or 'spending'") }
        return direction
    }
}

/// JSON Schema snippets for the input schemas.
enum Schema {
    static func object(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        var schema: [String: JSONValue] = ["type": "object", "properties": .object(properties), "additionalProperties": false]
        if !required.isEmpty { schema["required"] = .array(required.map(JSONValue.string)) }
        return .object(schema)
    }

    static func string(_ description: String) -> JSONValue {
        ["type": "string", "description": .string(description)]
    }

    static func date(_ description: String) -> JSONValue {
        ["type": "string", "format": "date", "description": .string(description + " (YYYY-MM-DD)")]
    }

    static func bool(_ description: String) -> JSONValue {
        ["type": "boolean", "description": .string(description)]
    }

    static func int(_ description: String, minimum: Int, maximum: Int) -> JSONValue {
        ["type": "integer", "minimum": .int(minimum), "maximum": .int(maximum), "description": .string(description)]
    }

    static func amount(_ description: String) -> JSONValue {
        ["type": "string", "pattern": "^-?[0-9]+([.,][0-9]{1,2})?$", "description": .string(description + " as a decimal string, e.g. \"12.50\"")]
    }

    static func choice(_ values: [String], _ description: String) -> JSONValue {
        ["type": "string", "enum": .array(values.map(JSONValue.string)), "description": .string(description)]
    }

    static let accountID = string("Account id from list_accounts")
    static let includePending = bool("Count pending (not yet booked) transactions too. Default true")
    static let direction = choice(["income", "spending"], "Only incoming or only outgoing money")
}
