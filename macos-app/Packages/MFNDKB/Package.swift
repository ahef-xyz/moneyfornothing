// swift-tools-version: 6.2
import PackageDescription

// DKB connector via the web-banking JSON API behind banking.dkb.de (until FinTS is registered).
let package = Package(
    name: "MFNDKB",
    defaultLocalization: "de",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "MFNDKB", targets: ["MFNDKB"]),
    ],
    dependencies: [
        .package(path: "../MFNCore"),
        .package(path: "../MFNScrape"),
        .package(path: "../MFNConformance"),
    ],
    targets: [
        .target(name: "MFNDKB", dependencies: [.product(name: "MFNCore", package: "MFNCore"), .product(name: "MFNScrape", package: "MFNScrape")], resources: [.process("Resources")]),
        .testTarget(
            name: "MFNDKBTests",
            dependencies: [
                "MFNDKB",
                .product(name: "MFNConformance", package: "MFNConformance"),
            ]
        ),
    ]
)
