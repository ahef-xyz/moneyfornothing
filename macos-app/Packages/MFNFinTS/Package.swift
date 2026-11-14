// swift-tools-version: 6.2
import PackageDescription

// Layout (who may change what – see docs/archive/phase-2/ORCHESTRATOR.md):
//   Wire/, Dialog/, Segments/   provided by the human; agents only fix bugs, with a reason
//   Banks/ING/, Parsers/MT940*, Parsers/MT535*            ING agent
//   Banks/DKB/, Parsers/CAMT*, TAN/Decoupled*             DKB agent
let package = Package(
    name: "MFNFinTS",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "MFNFinTS", targets: ["MFNFinTS"]),
    ],
    dependencies: [
        .package(path: "../MFNCore"),
        .package(path: "../MFNConformance"),
    ],
    targets: [
        .target(name: "MFNFinTS", dependencies: [.product(name: "MFNCore", package: "MFNCore")]),
        .testTarget(
            name: "MFNFinTSTests",
            dependencies: [
                "MFNFinTS",
                .product(name: "MFNConformance", package: "MFNConformance"),
            ]
        ),
    ]
)
