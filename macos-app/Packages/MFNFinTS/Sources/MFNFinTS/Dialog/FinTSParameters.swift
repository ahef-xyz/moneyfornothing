import Foundation

/// Bank parameter data (BPD): which business transactions in which versions, PIN/TAN rules.
public struct FinTSBPD: Sendable, Equatable {
    public var version: Int
    public var bankName: String?
    /// Supported versions per request type, e.g. `HKKAZ: [5, 6, 7]` (from `HIKAZS` etc.).
    public var versions: [String: [Int]]
    /// Request types that need a TAN (from `HIPINS`), e.g. `HKKAZ: true`.
    public var tanRequired: [String: Bool]
    /// Raw parameter segments, e.g. `HITANS` (TAN methods), for bank-specific parsing.
    public var parameterSegments: [FinTSSegment]

    public static let empty = FinTSBPD(version: 0, bankName: nil, versions: [:], tanRequired: [:], parameterSegments: [])

    public init(version: Int, bankName: String?, versions: [String: [Int]], tanRequired: [String: Bool], parameterSegments: [FinTSSegment]) {
        self.version = version
        self.bankName = bankName
        self.versions = versions
        self.tanRequired = tanRequired
        self.parameterSegments = parameterSegments
    }

    /// Reads BPD segments from a response; returns `nil` if the response has no `HIBPA`.
    public init?(_ response: FinTSResponse) {
        guard let hibpa = response.segment("HIBPA") else { return nil }
        version = hibpa[0].first.flatMap(Int.init) ?? 0
        bankName = hibpa[2].first
        var versions: [String: [Int]] = [:]
        var parameterSegments: [FinTSSegment] = []
        for segment in response.segments where segment.type.count == 6 && segment.type.hasPrefix("HI") && segment.type.hasSuffix("S") {
            let request = "HK" + segment.type.dropFirst(2).dropLast()
            versions[request, default: []].append(segment.version)
            parameterSegments.append(segment)
        }
        self.versions = versions.mapValues { Array(Set($0)).sorted() }
        self.parameterSegments = parameterSegments
        self.tanRequired = Self.parsePINTAN(response.segment("HIPINS"))
    }

    /// Highest version of `request` that both the bank and MFN support.
    public func bestVersion(of request: String, supported: [Int]) -> Int? {
        versions[request]?.filter(supported.contains).max()
    }

    public func supports(_ request: String) -> Bool {
        versions[request]?.isEmpty == false
    }

    public func parameters(_ type: String) -> [FinTSSegment] {
        parameterSegments.filter { $0.type == type }
    }

    /// `HIPINS` ends with pairs `<request type>:<J|N>`. Scan all components for that pattern.
    static func parsePINTAN(_ segment: FinTSSegment?) -> [String: Bool] {
        guard let segment else { return [:] }
        let texts = segment.elements.flatMap { $0.components.map { $0?.text } }
        var result: [String: Bool] = [:]
        var index = 0
        while index + 1 < texts.count {
            if let type = texts[index], type.count == 5, type.hasPrefix("HK"), let flag = texts[index + 1], flag == "J" || flag == "N" {
                result[type] = flag == "J"
                index += 2
            } else {
                index += 1
            }
        }
        return result
    }
}

/// One account from the user parameter data (`HIUPD`).
public struct FinTSAccount: Sendable, Equatable {
    public var accountNumber: String
    public var subAccount: String?
    public var blz: String
    public var iban: String?
    public var bic: String?
    public var customerID: String?
    /// FinTS account type code (1–9 giro, 10–19 savings, 30–39 depot, 50–59 credit card …).
    public var typeCode: Int?
    public var currency: String?
    public var ownerName: String?
    public var productName: String?
    /// Request types allowed for this account, e.g. `HKSAL`, `HKKAZ`.
    public var allowedTransactions: Set<String>

    public enum Kind: Sendable, Equatable {
        case giro, savings, timeDeposit, depot, loan, creditCard, fund, buildingSavings, insurance, other
    }

    public var kind: Kind {
        switch typeCode ?? 0 {
        case 1...9: .giro
        case 10...19: .savings
        case 20...29: .timeDeposit
        case 30...39: .depot
        case 40...49: .loan
        case 50...59: .creditCard
        case 60...69: .fund
        case 70...79: .buildingSavings
        case 80...89: .insurance
        default: .other
        }
    }

    /// Account reference for segment versions with international account (KTI):
    /// `IBAN:BIC:account:subaccount:280:BLZ`.
    public var kti: FinTSDataElement {
        FinTSDataElement(texts: [iban, bic, accountNumber, subAccount, "280", blz])
    }

    /// Account reference for older segment versions (KTV): `account:subaccount:280:BLZ`.
    public var ktv: FinTSDataElement {
        FinTSDataElement(texts: [accountNumber, subAccount, "280", blz])
    }
}

/// User parameter data (UPD): the user's accounts.
public struct FinTSUPD: Sendable, Equatable {
    public var version: Int
    public var accounts: [FinTSAccount]

    public static let empty = FinTSUPD(version: 0, accounts: [])

    public init(version: Int, accounts: [FinTSAccount]) {
        self.version = version
        self.accounts = accounts
    }

    public init?(_ response: FinTSResponse) {
        guard let hiupa = response.segment("HIUPA") else { return nil }
        version = hiupa[1].first.flatMap(Int.init) ?? 0
        accounts = response.segments("HIUPD").map(Self.account)
    }

    /// `HIUPD` v6: 1 KTV, 2 IBAN, 3 customer ID, 4 type, 5 currency, 6 name 1, 7 name 2,
    /// 8 product, 9 limit, 10… allowed transactions (`HKxxx:…`).
    static func account(_ segment: FinTSSegment) -> FinTSAccount {
        let ktv = segment[0]
        var allowed: Set<String> = []
        for element in segment.elements.dropFirst(9) {
            if let type = element[0], type.count == 5, type.hasPrefix("HK") { allowed.insert(type) }
        }
        let name = [segment[5].first, segment[6].first].compactMap { $0 }.joined(separator: " ")
        return FinTSAccount(
            accountNumber: ktv[0] ?? "",
            subAccount: ktv[1],
            blz: ktv[3] ?? "",
            iban: segment[1].first,
            bic: nil,
            customerID: segment[2].first,
            typeCode: segment[3].first.flatMap(Int.init),
            currency: segment[4].first,
            ownerName: name.isEmpty ? nil : name,
            productName: segment[7].first,
            allowedTransactions: allowed
        )
    }
}
