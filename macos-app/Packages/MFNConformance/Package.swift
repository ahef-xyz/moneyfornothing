// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MFNConformance",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "MFNConformance", targets: ["MFNConformance"]),
    ],
    dependencies: [
        .package(path: "../MFNCore"),
        .package(path: "../MFNMock"),
    ],
    targets: [
        .target(name: "MFNConformance", dependencies: ["MFNCore"]),
        .testTarget(name: "MFNConformanceTests", dependencies: ["MFNConformance", "MFNMock"]),
    ]
)
