// swift-tools-version: 6.2
import PackageDescription

// C24 connector. Owned by the C24 agent (docs/archive/phase-2/AGENT-C24.md); everything else is read-only for it.
let package = Package(
    name: "MFNC24",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "MFNC24", targets: ["MFNC24"]),
    ],
    dependencies: [
        .package(path: "../MFNCore"),
        .package(path: "../MFNScrape"),
        .package(path: "../MFNConformance"),
    ],
    targets: [
        .target(name: "MFNC24", dependencies: [.product(name: "MFNCore", package: "MFNCore"), .product(name: "MFNScrape", package: "MFNScrape")]),
        .testTarget(
            name: "MFNC24Tests",
            dependencies: [
                "MFNC24",
                .product(name: "MFNConformance", package: "MFNConformance"),
            ]
        ),
    ]
)
