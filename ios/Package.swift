// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Roomprint",
    platforms: [
        .iOS(.v17),
    ],
    products: [
        .library(name: "Roomprint", targets: ["Roomprint"]),
    ],
    targets: [
        .target(
            name: "Roomprint",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
