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
            swiftSettings: [.swiftLanguageMode(.v5)],
            // Stamp the SDK we really build against (iOS 26.5) into LC_BUILD_VERSION; the Linux
            // linker otherwise writes the deployment target, and App Store Connect rejects
            // anything below the iOS 26 SDK. Keep in step with SDK_VERSION in tools/testflight.sh.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-platform_version", "-Xlinker", "ios",
                                           "-Xlinker", "17.0", "-Xlinker", "26.5"])]
        ),
    ]
)
