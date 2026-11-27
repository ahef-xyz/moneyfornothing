// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MFNIntelligence",
    defaultLocalization: "de",
    platforms: [.macOS(.v26)],
    products: [
        // kNN over the user's own bookings (NaturalLanguage) and the Foundation Models stage.
        .library(name: "MFNIntelligence", targets: ["MFNIntelligence"]),
    ],
    dependencies: [
        .package(path: "../MFNCore"),
    ],
    targets: [
        .target(
            name: "MFNIntelligence",
            dependencies: [.product(name: "MFNCore", package: "MFNCore")]
        ),
        // The eval set lives in Tests/Fixtures (CLAUDE.md §8); tests read it via #filePath.
        .testTarget(
            name: "MFNIntelligenceTests",
            dependencies: ["MFNIntelligence", .product(name: "MFNCore", package: "MFNCore")]
        ),
    ]
)
