// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AnsiCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "AnsiCore", targets: ["AnsiCore"]),
        // File transfer test driver (interop with lrzsz and C-Kermit). Never part of the app bundle.
        .executable(name: "ansixfer", targets: ["ansixfer"]),
    ],
    targets: [
        .target(name: "AnsiCore", resources: [.copy("Resources/Fonts")]),
        .executableTarget(name: "ansixfer", dependencies: ["AnsiCore"]),
        .testTarget(name: "AnsiCoreTests", dependencies: ["AnsiCore"], resources: [.copy("Fixtures")]),
    ],
    swiftLanguageVersions: [.v5]
)
