// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AnsiCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "AnsiCore", targets: ["AnsiCore"]),
    ],
    targets: [
        .target(name: "AnsiCore", resources: [.copy("Resources/Fonts")]),
        .testTarget(name: "AnsiCoreTests", dependencies: ["AnsiCore"], resources: [.copy("Fixtures")]),
    ],
    swiftLanguageVersions: [.v5]
)
