import Compression
import Foundation
import Testing
@testable import SkylineCore

/// CR #7.1: the raster PNG reader must reject anything malformed without trapping.
struct PalettePNGFuzzTests {
    static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    static func chunk(_ type: String, _ body: [UInt8], badCRC: Bool = false) -> [UInt8] {
        let t = Array(type.utf8)
        var crc = PalettePNG.crc32((t + body)[...])
        if badCRC { crc ^= 1 }
        return be32(UInt32(body.count)) + t + body + be32(crc)
    }
    static func deflate(_ raw: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: raw.count + 1024)
        let n = compression_encode_buffer(&out, out.count, raw, raw.count, nil, COMPRESSION_ZLIB)
        return [0x78, 0x9C] + Array(out[0..<n]) + [0, 0, 0, 0] // adler not checked
    }
    static func ihdr(_ w: UInt32, _ h: UInt32, depth: UInt8 = 8, type: UInt8 = 3, interlace: UInt8 = 0) -> [UInt8] {
        chunk("IHDR", be32(w) + be32(h) + [depth, type, 0, 0, interlace])
    }
    static let sig: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
    static func png(w: Int = 4, h: Int = 3, raw: [UInt8]? = nil, ihdrChunk: [UInt8]? = nil, trns: Bool = true) -> [UInt8] {
        let rows: [UInt8] = raw ?? (0..<h).flatMap { y -> [UInt8] in [0] + (0..<w).map { UInt8(($0 + y) % 4) } }
        return sig + (ihdrChunk ?? ihdr(UInt32(w), UInt32(h))) + chunk("PLTE", (0..<12).map { UInt8($0 * 20) })
            + (trns ? chunk("tRNS", [0, 0]) : []) + chunk("IDAT", deflate(rows)) + chunk("IEND", [])
    }

    @Test func decodesAWellFormedImage() throws {
        let img = try #require(PalettePNG.decode(Data(Self.png())))
        #expect(img.width == 4 && img.height == 3 && img.palette.count == 4)
        #expect(img.indices == [0, 1, 2, 3, 1, 2, 3, 0, 2, 3, 0, 1])
        #expect(img.transparent[0] && img.transparent[1] && !img.transparent[2] && img.transparent[200])
    }

    @Test func rejectsHugeAndOverflowingDimensions() {
        for (w, h) in [(UInt32.max, UInt32.max), (0x8000_0000, 2), (4097, 1), (1, 4097), (0, 5), (100_000, 100_000)] {
            #expect(PalettePNG.decode(Data(Self.png(ihdrChunk: Self.ihdr(w, h)))) == nil)
        }
    }

    @Test func rejectsBadHeadersAndChunks() {
        #expect(PalettePNG.decode(Data(Self.png(ihdrChunk: Self.ihdr(4, 3, depth: 4)))) == nil)
        #expect(PalettePNG.decode(Data(Self.png(ihdrChunk: Self.ihdr(4, 3, type: 2)))) == nil)
        #expect(PalettePNG.decode(Data(Self.png(ihdrChunk: Self.ihdr(4, 3, interlace: 1)))) == nil)
        #expect(PalettePNG.decode(Data(Self.png(ihdrChunk: Self.chunk("IHDR", [0, 0, 0, 4])))) == nil) // short IHDR
        #expect(PalettePNG.decode(Data(Self.png(ihdrChunk: Self.chunk("IHDR", Self.be32(4) + Self.be32(3) + [8, 3, 0, 0, 0], badCRC: true)))) == nil)
        // IHDR not first / twice.
        var p = Self.png(); p.insert(contentsOf: Self.chunk("tEXt", [65]), at: 8)
        #expect(PalettePNG.decode(Data(p)) == nil)
        p = Self.png(); p.insert(contentsOf: Self.ihdr(4, 3), at: 33)
        #expect(PalettePNG.decode(Data(p)) == nil)
        // Chunk length past the end.
        p = Self.png(); p.replaceSubrange(33..<37, with: Self.be32(0x7FFF_FFFF))
        #expect(PalettePNG.decode(Data(p)) == nil)
        // Bad filter byte.
        let rows: [UInt8] = [9, 0, 1, 2, 3, 0, 0, 1, 2, 3, 0, 0, 1, 2, 3]
        #expect(PalettePNG.decode(Data(Self.png(raw: rows))) == nil)
        // Short image data, and too much (stops at the expected size).
        #expect(PalettePNG.decode(Data(Self.png(raw: [0, 1, 2]))) == nil)
        #expect(PalettePNG.decode(Data(Self.png(raw: [UInt8](repeating: 0, count: 100)))) == nil)
        #expect(PalettePNG.decode(Data()) == nil)
    }

    @Test func zlibBombIsStoppedAtTheExpectedSize() {
        // 64 MB of zeros deflates to ~64 KB; the image only allows (4+1)*3 bytes.
        let bomb = Self.deflate([UInt8](repeating: 0, count: 64 << 20))
        let p = Self.sig + Self.ihdr(4, 3) + Self.chunk("PLTE", [UInt8](repeating: 1, count: 12)) + Self.chunk("IDAT", bomb) + Self.chunk("IEND", [])
        #expect(PalettePNG.decode(Data(p)) == nil)
        #expect(PalettePNG.inflate(bomb.dropFirst(2)[...], exactly: 15) == nil)
        // Oversized files are refused before parsing.
        #expect(PalettePNG.decode(Data(count: PalettePNG.maxFileBytes + 1)) == nil)
    }

    @Test func truncationsAndBitFlipsNeverCrash() throws {
        let real = try [UInt8](RidgeRasterTests.fixture("OKX_N0B_202610161748", "png"))
        #expect(PalettePNG.decode(Data(real)) != nil)
        for cut in Swift.stride(from: 0, to: real.count, by: 97) { #expect(PalettePNG.decode(Data(real[0..<cut])) == nil) }
        var rng = SystemRandomNumberGenerator()
        var seed: UInt64 = 0x5EED
        func next() -> UInt64 { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return seed >> 33 }
        _ = rng.next()
        for _ in 0..<300 {
            var b = real
            for _ in 0..<(1 + Int(next() % 4)) { let i = Int(next()) % b.count; b[i] ^= UInt8(1 << (next() % 8)) }
            // Must not trap; most flips fail the CRC, the rest decode to a valid-sized image or nil.
            if let img = PalettePNG.decode(Data(b)) { #expect(img.indices.count == img.width * img.height) }
        }
    }
}
