import Foundation

/// Access to `Fixtures/<Bank>/` (anonymised real bank answers, created only by the human).
///
/// Works from any checkout or Herdr worktree: walks up from the calling test file until it finds
/// the repository's `Fixtures` directory. Tests never talk to a real bank.
///
/// ```swift
/// let mt940 = try Fixtures.data(.ing, "mt940-giro.sta")
/// guard Fixtures.exists(.ing, "mt535.sta") else { return } // missing fixture: report in STATUS.md
/// ```
public enum Fixtures {
    public enum Bank: String, Sendable, CaseIterable {
        case ing = "ING"
        case dkb = "DKB"
        case tradeRepublic = "TradeRepublic"
        case c24 = "C24"
        case easybank = "Easybank"
    }

    public struct Missing: Error, CustomStringConvertible {
        public let path: String
        public var description: String { "Fixture fehlt: \(path) – in STATUS.md auflisten" }
    }

    public static func directory(_ bank: Bank, file: StaticString = #filePath) throws -> URL {
        var url = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        while url.path != "/" {
            let candidate = url.appendingPathComponent("Fixtures", isDirectory: true)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue,
               FileManager.default.fileExists(atPath: candidate.appendingPathComponent("README.md").path) {
                return candidate.appendingPathComponent(bank.rawValue, isDirectory: true)
            }
            url.deleteLastPathComponent()
        }
        throw Missing(path: "Fixtures/ (Repository-Wurzel nicht gefunden)")
    }

    public static func url(_ bank: Bank, _ name: String, file: StaticString = #filePath) throws -> URL {
        let url = try directory(bank, file: file).appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { throw Missing(path: "Fixtures/\(bank.rawValue)/\(name)") }
        return url
    }

    public static func data(_ bank: Bank, _ name: String, file: StaticString = #filePath) throws -> Data {
        try Data(contentsOf: url(bank, name, file: file))
    }

    public static func exists(_ bank: Bank, _ name: String, file: StaticString = #filePath) -> Bool {
        (try? url(bank, name, file: file)) != nil
    }

    /// All fixture files of a bank (excluding README.md), sorted.
    public static func list(_ bank: Bank, file: StaticString = #filePath) -> [String] {
        guard let directory = try? directory(bank, file: file),
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names.filter { $0 != "README.md" && !$0.hasPrefix(".") }.sorted()
    }
}
