import Foundation

/// One TAN method from `HITANS` (two-step parameters), reduced to what MFN needs.
///
/// Layout of `HITANS` element 4 (index 3), flattened by the wire parser:
/// `oneStepAllowed : multipleTANs : hashAlgorithm : <method 1> : <method 2> …`
/// with 21 fields per method in v6 and 26 in v7 (v7 adds the decoupled polling parameters).
public struct DecoupledTANParameters: Sendable, Equatable {
    public var securityFunction: String
    public var name: String
    /// `HITANS` segment version the method was announced in (= `HKTAN` version to use).
    public var hktanVersion: Int
    /// Decoupled method (DKB-App `942`). Derived from the v7 polling fields or the method name.
    public var isDecoupled: Bool
    /// Maximum number of status polls; `nil` = not limited by the bank.
    public var maxStatusRequests: Int?
    public var waitBeforeFirstStatus: Duration
    public var waitBetweenStatus: Duration

    public static let defaultWaitBeforeFirstStatus: Duration = .seconds(2)
    public static let defaultWaitBetweenStatus: Duration = .seconds(2)
    /// Client-side limit when the bank sets none: about five minutes at the default pace.
    public static let defaultMaxStatusRequests = 150

    public init(securityFunction: String, name: String, hktanVersion: Int, isDecoupled: Bool, maxStatusRequests: Int?, waitBeforeFirstStatus: Duration, waitBetweenStatus: Duration) {
        self.securityFunction = securityFunction
        self.name = name
        self.hktanVersion = hktanVersion
        self.isDecoupled = isDecoupled
        self.maxStatusRequests = maxStatusRequests
        self.waitBeforeFirstStatus = waitBeforeFirstStatus
        self.waitBetweenStatus = waitBetweenStatus
    }

    /// Fallback when the BPD has no usable `HITANS` for the method.
    public static func fallback(securityFunction: String, hktanVersion: Int = 7) -> DecoupledTANParameters {
        DecoupledTANParameters(
            securityFunction: securityFunction, name: "", hktanVersion: hktanVersion, isDecoupled: true,
            maxStatusRequests: nil, waitBeforeFirstStatus: defaultWaitBeforeFirstStatus, waitBetweenStatus: defaultWaitBetweenStatus
        )
    }

    /// Effective poll limit (bank value, else the client default).
    public var statusRequestLimit: Int {
        max(1, maxStatusRequests ?? Self.defaultMaxStatusRequests)
    }

    static let fieldsPerMethod = [6: 21, 7: 26]

    /// All methods from all `HITANS` segments of the BPD (v6 and v7). The highest version wins
    /// for a security function announced in several versions.
    public static func all(in bpd: FinTSBPD) -> [DecoupledTANParameters] {
        var bySecurityFunction: [String: DecoupledTANParameters] = [:]
        for segment in bpd.parameters("HITANS").sorted(by: { $0.version < $1.version }) {
            for method in methods(in: segment) {
                bySecurityFunction[method.securityFunction] = method
            }
        }
        return bySecurityFunction.values.sorted { $0.securityFunction < $1.securityFunction }
    }

    /// The method `securityFunction` from the BPD, or `nil` if the bank does not offer it.
    public static func method(_ securityFunction: String, in bpd: FinTSBPD) -> DecoupledTANParameters? {
        all(in: bpd).first { $0.securityFunction == securityFunction }
    }

    static func methods(in segment: FinTSSegment) -> [DecoupledTANParameters] {
        guard let width = fieldsPerMethod[segment.version] else { return [] }
        let values = segment[3].components.map { $0?.text }
        var result: [DecoupledTANParameters] = []
        var index = 3
        while index + width <= values.count {
            let fields = Array(values[index..<(index + width)])
            index += width
            // A security function is a three-digit code (900…999); anything else = misaligned.
            guard let function = fields[0], function.count == 3, function.allSatisfy(\.isNumber) else { break }
            let name = fields[5] ?? ""
            if segment.version >= 7 {
                let maxPolls = fields[21].flatMap(Int.init)
                let first = fields[22].flatMap(Int.init)
                let between = fields[23].flatMap(Int.init)
                let decoupled = maxPolls != nil || first != nil || between != nil || name.localizedCaseInsensitiveContains("app")
                result.append(DecoupledTANParameters(
                    securityFunction: function, name: name, hktanVersion: segment.version, isDecoupled: decoupled,
                    maxStatusRequests: maxPolls.flatMap { $0 > 0 ? $0 : nil },
                    waitBeforeFirstStatus: first.map { .seconds(max(1, $0)) } ?? defaultWaitBeforeFirstStatus,
                    waitBetweenStatus: between.map { .seconds(max(1, $0)) } ?? defaultWaitBetweenStatus
                ))
            } else {
                result.append(DecoupledTANParameters(
                    securityFunction: function, name: name, hktanVersion: segment.version,
                    isDecoupled: name.localizedCaseInsensitiveContains("app"),
                    maxStatusRequests: nil, waitBeforeFirstStatus: defaultWaitBeforeFirstStatus, waitBetweenStatus: defaultWaitBetweenStatus
                ))
            }
        }
        return result
    }
}
