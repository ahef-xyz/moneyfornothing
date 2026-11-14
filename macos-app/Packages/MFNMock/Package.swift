// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MFNMock",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "MFNMock", targets: ["MFNMock"]),
    ],
    dependencies: [
        .package(path: "../MFNCore"),
    ],
    targets: [
        .target(name: "MFNMock", dependencies: ["MFNCore"]),
        .testTarget(name: "MFNMockTests", dependencies: ["MFNMock"]),
    ]
)
