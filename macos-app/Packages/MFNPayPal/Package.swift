// swift-tools-version: 6.2
import PackageDescription

// PayPal connector (web: www.paypal.com, visible web login, JSON behind the activity page).
let package = Package(
    name: "MFNPayPal",
    defaultLocalization: "de",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "MFNPayPal", targets: ["MFNPayPal"]),
    ],
    dependencies: [
        .package(path: "../MFNCore"),
        .package(path: "../MFNScrape"),
        .package(path: "../MFNConformance"),
    ],
    targets: [
        .target(name: "MFNPayPal", dependencies: [.product(name: "MFNCore", package: "MFNCore"), .product(name: "MFNScrape", package: "MFNScrape")], resources: [.process("Resources")]),
        .testTarget(
            name: "MFNPayPalTests",
            dependencies: [
                "MFNPayPal",
                .product(name: "MFNConformance", package: "MFNConformance"),
            ]
        ),
    ]
)
