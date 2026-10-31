import Testing

/// IEM raster fixtures are palette PNGs. Linux has no Apple Compression framework, and this
/// package does not link zlib, so those fixtures are not inflated here. macOS `swift test` decodes them.
enum RasterFixtureGate {
    static let canInflate: Bool = {
        #if canImport(Compression)
        true
        #else
        false
        #endif
    }()
}

extension Trait where Self == ConditionTrait {
    /// Skip on Linux. The comment is the skip reason reported by `swift test`.
    static var rasterFixtures: Self {
        .enabled(if: RasterFixtureGate.canInflate,
                 "Linux has no Apple Compression framework, so IEM raster fixtures are not inflated. macOS swift test decodes them.")
    }
}
