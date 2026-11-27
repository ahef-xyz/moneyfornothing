// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MFNCore",
    defaultLocalization: "de",
    platforms: [.macOS(.v26)],
    products: [
        // Models, protocol, sync. No database: connector packages depend only on this.
        .library(name: "MFNCore", targets: ["MFNCore"]),
        // Encrypted persistence (SQLCipher). Used by the app.
        .library(name: "MFNStore", targets: ["MFNStore"]),
    ],
    dependencies: [
        // The only third-party dependency: official SQLCipher binary (BSD-style, checksum-pinned).
        .package(url: "https://github.com/sqlcipher/SQLCipher.swift.git", exact: "4.20.0"),
    ],
    targets: [
        .target(name: "MFNCore", resources: [.process("Localizable.xcstrings")]),
        // `sqlite3_key` is only declared with SQLITE_HAS_CODEC; this shim exposes it to Swift.
        .target(
            name: "MFNSQLCipherKey",
            dependencies: [.product(name: "SQLCipher", package: "SQLCipher.swift")],
            cSettings: [.define("SQLITE_HAS_CODEC")]
        ),
        .target(
            name: "MFNStore",
            dependencies: [
                "MFNCore",
                "MFNSQLCipherKey",
                .product(name: "SQLCipher", package: "SQLCipher.swift"),
            ]
        ),
        .testTarget(name: "MFNCoreTests", dependencies: ["MFNCore"]),
        .testTarget(name: "MFNStoreTests", dependencies: ["MFNStore"]),
    ]
)
