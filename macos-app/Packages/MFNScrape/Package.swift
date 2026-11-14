// swift-tools-version: 6.2
import PackageDescription

// Shared base for scraping connectors (C24, easybank). Provided by the human; connector agents
// use it read-only and put wishes into PROPOSALS.md.
let package = Package(
    name: "MFNScrape",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "MFNScrape", targets: ["MFNScrape"]),
    ],
    dependencies: [
        .package(path: "../MFNCore"),
    ],
    targets: [
        .target(name: "MFNScrape", dependencies: [.product(name: "MFNCore", package: "MFNCore")]),
        .testTarget(name: "MFNScrapeTests", dependencies: ["MFNScrape"]),
    ]
)
