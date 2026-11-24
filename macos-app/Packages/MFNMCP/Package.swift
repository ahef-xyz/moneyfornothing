// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MFNMCP",
    platforms: [.macOS(.v26)],
    products: [
        // MCP server: message types, read-only ledger tools and the Unix socket listener
        // (docs/v0.6.0.md). No third-party code: MCP over JSON-RPC is written by hand.
        .library(name: "MFNMCP", targets: ["MFNMCP"]),
    ],
    dependencies: [
        .package(path: "../MFNCore"),
        .package(path: "../MFNMock"),
    ],
    targets: [
        .target(
            name: "MFNMCP",
            dependencies: [.product(name: "MFNCore", package: "MFNCore")],
            // audit_token_to_pid (peer of the socket).
            linkerSettings: [.linkedLibrary("bsm")]
        ),
        .testTarget(
            name: "MFNMCPTests",
            dependencies: [
                "MFNMCP",
                .product(name: "MFNCore", package: "MFNCore"),
                .product(name: "MFNMock", package: "MFNMock"),
            ]
        ),
    ]
)
