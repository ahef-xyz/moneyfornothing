// swift-tools-version: 6.2
import PackageDescription

// easybank connector. Owned by the easybank agent (docs/archive/phase-2/AGENT-easybank.md); everything else is read-only for it.
let package = Package(
    name: "MFNEasybank",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "MFNEasybank", targets: ["MFNEasybank"]),
    ],
    dependencies: [
        .package(path: "../MFNCore"),
        .package(path: "../MFNScrape"),
        .package(path: "../MFNConformance"),
    ],
    targets: [
        .target(name: "MFNEasybank", dependencies: [.product(name: "MFNCore", package: "MFNCore"), .product(name: "MFNScrape", package: "MFNScrape")]),
        .testTarget(
            name: "MFNEasybankTests",
            dependencies: [
                "MFNEasybank",
                .product(name: "MFNConformance", package: "MFNConformance"),
            ]
        ),
    ]
)
