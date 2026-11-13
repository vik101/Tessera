// swift-tools-version: 6.0
//
// Tessera — automatic window tiling for macOS.
//
// Build:   swift build                (debug binary)
//          ./scripts/build-app.sh     (assembles Tessera.app)
// Test:    swift test
//
import PackageDescription

let package = Package(
    name: "Tessera",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Tessera", targets: ["Tessera"]),
        .library(name: "TesseraCore", targets: ["TesseraCore"]),
    ],
    dependencies: [
        // Signed, user-approved updates.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.4"),
    ],
    targets: [
        // Pure Swift logic: layout maths, window model, shortcuts, setups.
        // No AppKit, so it is fast to test and easy to reason about.
        .target(name: "TesseraCore"),

        // The macOS app: Accessibility, overlays, menu bar, Settings.
        .executableTarget(
            name: "Tessera",
            dependencies: [
                "TesseraCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
            ]
        ),

        .testTarget(name: "TesseraCoreTests", dependencies: ["TesseraCore"]),
    ]
)
