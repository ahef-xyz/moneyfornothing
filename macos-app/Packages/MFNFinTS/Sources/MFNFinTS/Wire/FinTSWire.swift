import Foundation

public enum FinTSWireError: Error, Equatable, Sendable {
    case unterminatedSegment
    case invalidBinaryLength(offset: Int)
    case binaryOutOfBounds(offset: Int)
    case invalidHeader(String)
    /// A character outside ISO-8859-1 (e.g. `€`) cannot be sent.
    case notLatin1(String)
}

/// FinTS 3.0 syntax: segments end with `'`, data elements are separated by `+`, group
/// components by `:`, `?` escapes the next character, `@len@` introduces `len` raw bytes.
/// Text is ISO-8859-1. Everything works on bytes so binary lengths stay exact.
public enum FinTSWire {
    static let segmentEnd = UInt8(ascii: "'")
    static let elementSeparator = UInt8(ascii: "+")
    static let groupSeparator = UInt8(ascii: ":")
    static let escape = UInt8(ascii: "?")
    static let binaryMarker = UInt8(ascii: "@")

    // MARK: - Parse

    public static func parse(_ bytes: [UInt8]) throws(FinTSWireError) -> [FinTSSegment] {
        var segments: [FinTSSegment] = []
        var elements: [FinTSDataElement] = []
        var components: [FinTSValue?] = []
        var text: [UInt8] = []
        var binary: Data?
        var hasContent = false
        var index = 0

        func endComponent() {
            if let data = binary {
                components.append(.binary(data))
            } else {
                components.append(text.isEmpty ? nil : .text(latin1(text)))
            }
            text = []
            binary = nil
        }

        while index < bytes.count {
            let byte = bytes[index]
            switch byte {
            case escape:
                index += 1
                guard index < bytes.count else { throw .unterminatedSegment }
                text.append(bytes[index])
                hasContent = true
            case binaryMarker where text.isEmpty && binary == nil:
                let lengthStart = index + 1
                guard let lengthEnd = bytes[lengthStart...].firstIndex(of: binaryMarker),
                      let length = Int(latin1(Array(bytes[lengthStart..<lengthEnd]))), length >= 0
                else { throw .invalidBinaryLength(offset: index) }
                let dataStart = lengthEnd + 1
                guard dataStart + length <= bytes.count else { throw .binaryOutOfBounds(offset: index) }
                binary = Data(bytes[dataStart..<(dataStart + length)])
                index = dataStart + length - 1
                hasContent = true
            case groupSeparator:
                endComponent()
            case elementSeparator:
                endComponent()
                elements.append(FinTSDataElement(components))
                components = []
            case segmentEnd:
                endComponent()
                elements.append(FinTSDataElement(components))
                components = []
                segments.append(try segment(from: elements))
                elements = []
                hasContent = false
            default:
                let isLineBreak = byte == UInt8(ascii: "\r") || byte == UInt8(ascii: "\n")
                if isLineBreak, !hasContent, elements.isEmpty, components.isEmpty {
                    break // line breaks between segments (some fixtures are wrapped)
                }
                text.append(byte)
                hasContent = true
            }
            index += 1
        }
        guard !hasContent, elements.isEmpty, components.isEmpty else { throw .unterminatedSegment }
        return segments
    }

    public static func parse(_ data: Data) throws(FinTSWireError) -> [FinTSSegment] {
        try parse([UInt8](data))
    }

    private static func segment(from elements: [FinTSDataElement]) throws(FinTSWireError) -> FinTSSegment {
        guard let header = elements.first,
              let type = header[0],
              let number = header[1].flatMap(Int.init),
              let version = header[2].flatMap(Int.init)
        else { throw .invalidHeader(elements.first?.description ?? "") }
        return FinTSSegment(
            type: type,
            version: version,
            number: number,
            reference: header[3].flatMap(Int.init),
            elements: Array(elements.dropFirst())
        )
    }

    // MARK: - Encode

    public static func encode(_ segments: [FinTSSegment]) throws(FinTSWireError) -> [UInt8] {
        var out: [UInt8] = []
        for segment in segments {
            try encode(segment, into: &out)
        }
        return out
    }

    public static func encode(_ segment: FinTSSegment) throws(FinTSWireError) -> [UInt8] {
        var out: [UInt8] = []
        try encode(segment, into: &out)
        return out
    }

    public static func encode(_ segment: FinTSSegment, into out: inout [UInt8]) throws(FinTSWireError) {
        var elements = [segment.header] + segment.elements
        // Trailing empty elements may be omitted.
        while elements.count > 1, elements.last?.isEmpty == true { elements.removeLast() }
        for (elementIndex, element) in elements.enumerated() {
            if elementIndex > 0 { out.append(elementSeparator) }
            var components = element.components
            while components.count > 1, components.last == .some(nil) { components.removeLast() }
            for (componentIndex, component) in components.enumerated() {
                if componentIndex > 0 { out.append(groupSeparator) }
                switch component {
                case nil:
                    break
                case let .text(value)?:
                    try appendEscaped(value, to: &out)
                case let .binary(data)?:
                    out.append(contentsOf: Array("@\(data.count)@".utf8))
                    out.append(contentsOf: data)
                }
            }
        }
        out.append(segmentEnd)
    }

    static func appendEscaped(_ text: String, to out: inout [UInt8]) throws(FinTSWireError) {
        for scalar in text.unicodeScalars {
            guard scalar.value <= 0xFF else { throw .notLatin1(String(scalar)) }
            let byte = UInt8(scalar.value)
            if byte == escape || byte == segmentEnd || byte == elementSeparator || byte == groupSeparator || byte == binaryMarker {
                out.append(escape)
            }
            out.append(byte)
        }
    }

    /// ISO-8859-1 bytes → String (every byte maps to the scalar of the same value).
    public static func latin1(_ bytes: [UInt8]) -> String {
        String(String.UnicodeScalarView(bytes.map { Unicode.Scalar($0) }))
    }

    /// String → ISO-8859-1 bytes.
    public static func latin1Bytes(_ text: String) throws(FinTSWireError) -> [UInt8] {
        var out: [UInt8] = []
        for scalar in text.unicodeScalars {
            guard scalar.value <= 0xFF else { throw .notLatin1(String(scalar)) }
            out.append(UInt8(scalar.value))
        }
        return out
    }
}
