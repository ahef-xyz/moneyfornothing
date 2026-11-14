// swift-tools-version: 6.2
import PackageDescription

// Trade Republic connector. Owned by the Trade Republic agent (docs/archive/phase-2/AGENT-TradeRepublic.md); everything else is read-only for it.
let package = Package(
    name: "MFNTradeRepublic",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "MFNTradeRepublic", targets: ["MFNTradeRepublic"]),
    ],
    dependencies: [
        .package(path: "../MFNCore"),
        .package(path: "../MFNConformance"),
    ],
    targets: [
        .target(name: "MFNTradeRepublic", dependencies: [.product(name: "MFNCore", package: "MFNCore")]),
        .testTarget(
            name: "MFNTradeRepublicTests",
            dependencies: [
                "MFNTradeRepublic",
                .product(name: "MFNConformance", package: "MFNConformance"),
            ]
        ),
    ]
)
