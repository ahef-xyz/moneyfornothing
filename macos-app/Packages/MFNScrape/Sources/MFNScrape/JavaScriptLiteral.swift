import Foundation

/// Safe embedding of Swift strings (for example localized status texts) into login scripts.
public enum JavaScriptLiteral {
    /// `text` as a quoted, escaped JavaScript string literal (JSON is a subset of JavaScript).
    public static func string(_ text: String) -> String {
        guard let data = try? JSONEncoder().encode(text), let literal = String(data: data, encoding: .utf8) else { return "\"\"" }
        return literal
    }
}
