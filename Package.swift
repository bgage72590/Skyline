// swift-tools-version:5.9
import PackageDescription

// Skyline: native macOS weather app (main window + menu bar extra).
// SkylineCore is Foundation-only (models, parsing, blending, networking, caching)
// so it is fully unit-testable, even on Linux CI. The `Skyline` executable holds
// all SwiftUI / MapKit / CoreLocation code and is only built on macOS.

var targets: [Target] = [
    .target(
        name: "SkylineCore",
        path: "Sources/SkylineCore"
    ),
    .testTarget(
        name: "SkylineCoreTests",
        dependencies: ["SkylineCore"],
        path: "Tests/SkylineCoreTests",
        resources: [.copy("Fixtures")]
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
#endif

let package = Package(
    name: "Skyline",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
