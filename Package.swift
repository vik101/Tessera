// swift-tools-version: 6.0
//
// Tessera — Rectangle-style window snapping plus adaptive auto-tiling for macOS.
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
        .executable(name: "TesseraCLI", targets: ["TesseraCLI"]),
        .library(name: "TesseraCore", targets: ["TesseraCore"]),
    ],
    dependencies: [
        // Signed updates (the only outside library).
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.0"),
    ],
    targets: [
        // Pure maths: where snaps and tiles go, shortcuts. No AppKit, so it's quick to test.
        .target(name: "TesseraCore"),

        // The macOS app: Accessibility, hotkeys, menu bar, Settings.
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

        // The `tessera` command line tool (bundled in the app as Contents/Resources/bin/tessera).
        .executableTarget(name: "TesseraCLI", dependencies: ["TesseraCore"]),

        .testTarget(name: "TesseraCoreTests", dependencies: ["TesseraCore"]),
    ]
)
