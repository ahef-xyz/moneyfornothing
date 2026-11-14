import Foundation

/// One value inside a FinTS data element: text (ISO-8859-1) or binary (`@len@bytes`).
public enum FinTSValue: Equatable, Sendable, CustomStringConvertible {
    case text(String)
    case binary(Data)

    public var text: String? {
        if case let .text(value) = self { return value }
        return nil
    }

    public var binary: Data? {
        if case let .binary(value) = self { return value }
        return nil
    }

    public var description: String {
        switch self {
        case let .text(value): value
        case let .binary(value): "@\(value.count)@<binary>"
        }
    }
}

/// A data element (DE) or data element group (DEG). A plain DE is a group with one component.
/// `nil` components are empty positions (`::`).
public struct FinTSDataElement: Equatable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public var components: [FinTSValue?]

    public init(_ components: [FinTSValue?]) {
        self.components = components
    }

    /// Group of text components; `nil` = empty position.
    public init(texts: [String?]) {
        self.components = texts.map { $0.map(FinTSValue.text) }
    }

    public init(stringLiteral value: String) {
        self.components = [.text(value)]
    }

    public static let empty = FinTSDataElement([nil])

    public static func binary(_ data: Data) -> FinTSDataElement {
        FinTSDataElement([.binary(data)])
    }

    /// Text of component `index`, `nil` if missing, empty or binary.
    public subscript(index: Int) -> String? {
        guard components.indices.contains(index) else { return nil }
        return components[index]?.text
    }

    public var first: String? { self[0] }

    public var isEmpty: Bool { components.allSatisfy { $0 == nil } }

    public var description: String {
        components.map { $0?.description ?? "" }.joined(separator: ":")
    }
}

/// One FinTS segment, e.g. `HKSAL:3:7+DE00…+N'`.
public struct FinTSSegment: Equatable, Sendable, CustomStringConvertible {
    /// Segment identifier, e.g. `HKSAL`, `HIRMS`.
    public var type: String
    /// Position in the message (set when the message is built).
    public var number: Int
    public var version: Int
    /// Number of the request segment this answer refers to (responses only).
    public var reference: Int?
    /// Data elements after the header.
    public var elements: [FinTSDataElement]

    public init(type: String, version: Int, number: Int = 0, reference: Int? = nil, elements: [FinTSDataElement]) {
        self.type = type
        self.version = version
        self.number = number
        self.reference = reference
        self.elements = elements
    }

    /// Element `index` (0-based, after the header), or an empty element.
    public subscript(index: Int) -> FinTSDataElement {
        elements.indices.contains(index) ? elements[index] : .empty
    }

    var header: FinTSDataElement {
        var texts: [String?] = [type, String(number), String(version)]
        if let reference { texts.append(String(reference)) }
        return FinTSDataElement(texts: texts)
    }

    public var description: String {
        ([header] + elements).map(\.description).joined(separator: "+") + "'"
    }
}
