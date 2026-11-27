// swift-tools-version: 6.2
import PackageDescription

// Banks through YAXI's attested service with the user's own YAXI access (docs/v0.7.0.md).
// `routex-client-swift` is pinned exactly (CLAUDE.md §6, approved 2026-11-25).
let package = Package(
    name: "MFNYAXI",
    defaultLocalization: "de",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "MFNYAXI", targets: ["MFNYAXI"]),
    ],
    dependencies: [
        .package(path: "../MFNCore"),
        .package(path: "../MFNConformance"),
        .package(url: "https://github.com/yaxitech/routex-client-swift", exact: "0.6.2"),
    ],
    targets: [
        .target(
            name: "MFNYAXI",
            dependencies: [
                .product(name: "MFNCore", package: "MFNCore"),
                .product(name: "RoutexClient", package: "routex-client-swift"),
                .product(name: "RoutexModels", package: "routex-client-swift"),
                .product(name: "RoutexRefresh", package: "routex-client-swift"),
                .product(name: "RoutexSettlement", package: "routex-client-swift"),
                .product(name: "RoutexTickets", package: "routex-client-swift"),
            ],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "MFNYAXITests",
            dependencies: [
                "MFNYAXI",
                .product(name: "MFNConformance", package: "MFNConformance"),
            ]
        ),
    ]
)
