// swift-tools-version:5.9
import PackageDescription

// Skyline: native macOS weather app (main window + menu bar extra).
// SkylineCore is Foundation-only (models, parsing, blending, networking, caching)
// so it is fully unit-testable, even on Linux CI. The `Skyline` executable holds
// all SwiftUI / MapKit / CoreLocation code and is only built on macOS.

var targets: [Target] = [
    // Strictest data-race checking (L30): threading mistakes in the core are compile errors/warnings,
    // and the build is held at 0 warnings.
    .target(
        name: "SkylineCore",
        path: "Sources/SkylineCore",
        swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
    ),
    .testTarget(
        name: "SkylineCoreTests",
        dependencies: ["SkylineCore"],
        path: "Tests/SkylineCoreTests",
        resources: [.copy("Fixtures")],
        swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
    ),
]

var products: [Product] = [
    .library(name: "SkylineCore", targets: ["SkylineCore"]),
]

#if os(macOS)
targets.append(
    .executableTarget(
        name: "Skyline",
        dependencies: ["SkylineCore"],
        path: "Sources/Skyline"
    )
)
products.append(.executable(name: "Skyline", targets: ["Skyline"]))
// Desktop / Notification Center widget extension (T22). build-app.sh wraps the binary into
// Skyline.app/Contents/PlugIns/SkylineWidget.appex and signs it sandboxed.
targets.append(
    .executableTarget(
        name: "SkylineWidget",
        dependencies: ["SkylineCore"],
        path: "Sources/SkylineWidget",
        swiftSettings: [.unsafeFlags(["-application-extension"])],
        linkerSettings: [.unsafeFlags(["-Xlinker", "-application_extension"])]
    )
)
products.append(.executable(name: "SkylineWidget", targets: ["SkylineWidget"]))
#endif

let package = Package(
    name: "Skyline",
    platforms: [.macOS("15.0")],
    products: products,
    targets: targets
)
