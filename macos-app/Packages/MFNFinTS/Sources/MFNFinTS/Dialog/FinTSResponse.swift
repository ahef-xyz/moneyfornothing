import Foundation

/// A bank return code from `HIRMG` (message level) or `HIRMS` (segment level).
public struct FinTSReturnCode: Equatable, Sendable, CustomStringConvertible {
    public var code: String
    /// Data element reference inside the request segment (rarely used).
    public var elementReference: String?
    public var text: String
    public var parameters: [String]
    /// Request segment number this code refers to (`HIRMS` reference), `nil` for `HIRMG`.
    public var segmentReference: Int?

    public var isError: Bool { code.hasPrefix("9") }
    public var isWarning: Bool { code.hasPrefix("3") }

    public var description: String { "\(code) \(text)" }
}

/// Well-known return codes.
public enum FinTSCode {
    public static let ok = "0010"
    public static let executed = "0020"
    /// Order received, TAN/approval needed (two-step).
    public static let tanRequired = "0030"
    /// More data available; parameter 0 is the touchdown point (Aufsetzpunkt).
    public static let touchdown = "3040"
    /// Allowed TAN methods for this user (parameters = security function codes).
    public static let allowedTANMethods = "3920"
    /// Strong customer authentication required.
    public static let scaRequired = "3955"
    /// Decoupled: approve in the app, then poll with HKTAN process S.
    public static let decoupledPending = "3956"
    /// Strong customer authentication not required (`3076`): the order runs without approval.
    public static let scaNotRequired = "3076"
    /// Account without any booking (ING): no transactions available.
    public static let noTransactions = "9010"
    /// PIN wrong / access blocked family.
    public static let pinWrong = "9340"
    public static let pinBlocked = "9942"
    public static let dialogAborted = "9800"
    /// Message contains errors (`HIRMG`); details are in the segment-level `HIRMS` codes.
    public static let partiallyFaulty = "9050"
}

/// A parsed bank answer. Segments inside the `HNVSD` envelope are flattened into `segments`.
public struct FinTSResponse: Sendable, CustomStringConvertible {
    public let segments: [FinTSSegment]
    public let messageCodes: [FinTSReturnCode]
    public let segmentCodes: [FinTSReturnCode]

    public init(bytes: [UInt8]) throws(FinTSWireError) {
        var flat: [FinTSSegment] = []
        for segment in try FinTSWire.parse(bytes) {
            if segment.type == "HNVSD", let inner = segment[0].components.first??.binary {
                flat.append(contentsOf: try FinTSWire.parse(inner))
            } else {
                flat.append(segment)
            }
        }
        segments = flat
        messageCodes = flat.filter { $0.type == "HIRMG" }.flatMap { Self.codes(in: $0, reference: nil) }
        segmentCodes = flat.filter { $0.type == "HIRMS" }.flatMap { Self.codes(in: $0, reference: $0.reference) }
    }

    public var allCodes: [FinTSReturnCode] { messageCodes + segmentCodes }

    /// Dialog ID from `HNHBK` (element 3).
    public var dialogID: String? {
        segments.first { $0.type == "HNHBK" }?[2].first
    }

    public func segments(_ type: String) -> [FinTSSegment] {
        segments.filter { $0.type == type }
    }

    public func segment(_ type: String) -> FinTSSegment? {
        segments.first { $0.type == type }
    }

    /// Answer segments that refer to the request segment with `number`.
    public func answers(to number: Int) -> [FinTSSegment] {
        segments.filter { $0.reference == number && !$0.type.hasPrefix("HIRM") }
    }

    public func codes(for segmentNumber: Int) -> [FinTSReturnCode] {
        segmentCodes.filter { $0.segmentReference == segmentNumber }
    }

    public func has(_ code: String) -> Bool {
        allCodes.contains { $0.code == code }
    }

    /// Touchdown point (`3040`) for a request segment, if the bank has more data.
    public func touchdown(for segmentNumber: Int) -> String? {
        codes(for: segmentNumber).first { $0.code == FinTSCode.touchdown }?.parameters.first
    }

    public var errors: [FinTSReturnCode] { allCodes.filter(\.isError) }

    /// Segment types only, never content: safe for logs.
    public var description: String {
        "FinTSResponse(\(segments.map(\.type).joined(separator: ",")); codes \(allCodes.map(\.code).joined(separator: ",")))"
    }

    private static func codes(in segment: FinTSSegment, reference: Int?) -> [FinTSReturnCode] {
        segment.elements.compactMap { element in
            guard let code = element[0] else { return nil }
            let parameters = element.components.dropFirst(3).compactMap { $0?.text }
            return FinTSReturnCode(code: code, elementReference: element[1], text: element[2] ?? "", parameters: Array(parameters), segmentReference: reference)
        }
    }
}
