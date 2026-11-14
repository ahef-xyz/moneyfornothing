// swift-tools-version: 6.2
import PackageDescription

// N26 connector (GraphQL behind app.n26.com). Owned by the N26 agent; everything else is read-only for it.
let package = Package(
    name: "MFNN26",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "MFNN26", targets: ["MFNN26"]),
    ],
    dependencies: [
        .package(path: "../MFNCore"),
        .package(path: "../MFNScrape"),
        .package(path: "../MFNConformance"),
    ],
    targets: [
        .target(name: "MFNN26", dependencies: [.product(name: "MFNCore", package: "MFNCore"), .product(name: "MFNScrape", package: "MFNScrape")]),
        .testTarget(
            name: "MFNN26Tests",
            dependencies: [
                "MFNN26",
                .product(name: "MFNConformance", package: "MFNConformance"),
            ]
        ),
    ]
)
