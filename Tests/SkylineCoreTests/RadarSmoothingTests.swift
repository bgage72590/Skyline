import Foundation
import Testing
@testable import SkylineCore

/// PR B / LOCK B. Pure SkylineCore contract for the smoothing slider: the app target is not in `swift test`.
struct RadarSmoothingTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private var scans: [Date] {
        (0..<12).map { t0.addingTimeInterval(Double($0) * 300) }
    }

    private var siteFrames: [RadarFrame] {
        IEMRidge.frames(site: "OKX", scans: scans, range: .oneHour)
    }

    @Test func settingRoundTripAndClamp() {
        let name = "skyline.radarSmoothing.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        defer { suite.removePersistentDomain(forName: name) }
        #expect(suite.object(forKey: "savedLocations.v1") == nil)
        #expect(RadarSmoothing.key == "radarSmoothing.v1")
        #expect(RadarSmoothing.defaultValue == 0)
        #expect(RadarSmoothing.range == 0...1)
        #expect(RadarSmoothing.step == 0.1)
        #expect((80...100).contains(RadarSmoothing.debounceMilliseconds))
        #expect(RadarSmoothing.stored(in: suite) == 0)
        #expect(suite.object(forKey: RadarSmoothing.key) == nil)
        suite.set(0.26, forKey: RadarSmoothing.key)
        #expect(RadarSmoothing.stored(in: suite) == 0.3)
        suite.set(1.4, forKey: RadarSmoothing.key)
        #expect(RadarSmoothing.stored(in: suite) == 1)
        suite.set(-0.4, forKey: RadarSmoothing.key)
        #expect(RadarSmoothing.stored(in: suite) == 0)
        suite.set(Double.nan, forKey: RadarSmoothing.key)
        #expect(RadarSmoothing.stored(in: suite) == 0)
        #expect(RadarSmoothing.quantize(0.15) == 0.2)
        #expect(RadarSmoothing.quantize(0.45) == 0.5)
        #expect(RadarSmoothing.quantize(0.5) == 0.5)
        #expect(RadarSmoothing.quantize(.infinity) == 0)
        #expect(RadarSmoothing.stepIndex(0) == 0)
        #expect(RadarSmoothing.stepIndex(0.3) == 3)
        #expect(RadarSmoothing.stepIndex(1) == 10)
        #expect(suite.object(forKey: "savedLocations.v1") == nil)
    }

    @Test func helpAndAccessibility() {
        #expect(RadarSmoothing.accessibilityLabel == "Radar smoothing")
        #expect(RadarSmoothing.help == "Raw → Smooth (local radar). National composite: Raw at 0, smooth above 0.")
        #expect(RadarSmoothing.accessibilityValue(0) == "Raw")
        #expect(RadarSmoothing.accessibilityValue(0.04) == "Raw")
        #expect(RadarSmoothing.accessibilityValue(1) == "Smooth")
        #expect(RadarSmoothing.accessibilityValue(0.3) == "30%")
        #expect(RadarSmoothing.showsControl(for: .reflectivity))
        #expect(!RadarSmoothing.showsControl(for: .rain1h))
        #expect(!RadarSmoothing.showsControl(for: .rain24h))
    }

    @Test func retagOnlyRawFramesAndOrder() throws {
        let smooth = siteFrames
        let pending = IEMRidge.newestBlocky(smooth, site: "OKX")
        let blocky = try #require(pending.last)
        #expect(RadarSmoothing.retag([blocky], q: 0.7)[0].urlTemplate == blocky.urlTemplate)

        let tagged = RadarSmoothing.retag(smooth, q: 0.4)
        #expect(tagged.map(\.time) == smooth.map(\.time))
        #expect(tagged.map(\.isForecast) == smooth.map(\.isForecast))
        #expect(tagged.map(\.id) != smooth.map(\.id))
        #expect(RadarSmoothing.retag(tagged, q: 0.4).map(\.urlTemplate) == tagged.map(\.urlTemplate))
        let other = RadarSmoothing.retag(smooth, q: 0.5)
        #expect(other.map(\.id) != tagged.map(\.id))
        #expect(tagged[0].urlTemplate.contains("&sm=4"))
        #expect(RadarSmoothing.retag(smooth, q: 0)[0].urlTemplate.split(separator: "&").contains("sm=0"))
        #expect(RadarSmoothing.retag(smooth, q: 1)[0].urlTemplate.split(separator: "&").contains("sm=10"))

        let masked = RadarQC.masked(tagged, latestMask: try #require(scans.last))
        let url = masked[0].urlTemplate
        let hash = try #require(url.firstIndex(of: "#"))
        let frag = url[url.index(after: hash)...]
        #expect(frag.hasPrefix("raw="))
        let sm = try #require(frag.range(of: "&sm=4"))
        let qc = try #require(frag.range(of: "&qc="))
        #expect(sm.lowerBound < qc.lowerBound)
        #expect(RadarSmoothing.retag(masked, q: 0.4).map(\.urlTemplate) == masked.map(\.urlTemplate))

        let tile = try #require(masked[0].url(z: 5, x: 9, y: 12))
        let parts = RadarQC.split(tile)
        #expect(parts.smoothing == 0.4)
        #expect(parts.raster?.contains("OKX_N0B_") == true)
        #expect(!parts.image.absoluteString.contains("#"))
        #expect(!parts.image.absoluteString.contains("sm="))
        #expect(parts.maskTemplate != nil)
        let bare = try #require(smooth[0].url(z: 5, x: 9, y: 12))
        #expect(RadarQC.split(bare).smoothing == nil)

        let maskedBlocky = RadarQC.masked(pending, latestMask: try #require(scans.last))
        #expect(RadarSmoothing.retag([try #require(maskedBlocky.last)], q: 0.8)[0].urlTemplate
                == maskedBlocky.last?.urlTemplate)

        let taggedPending = RadarSmoothing.retag(pending, q: 0.2)
        #expect(IEMRidge.isPendingSmooth(taggedPending))
        #expect(taggedPending.last?.urlTemplate == blocky.urlTemplate)
        #expect(taggedPending.dropLast().allSatisfy { $0.urlTemplate.contains("#raw=") && $0.urlTemplate.contains("&sm=2") })
    }

    @Test func nonRawSourcesAreByteIdentical() throws {
        let composite = IEMNexrad.frames(latest: t0, range: .oneHour)
        let initTime = try #require(ISO8601DateFormatter().date(from: "2026-10-11T23:00:00Z"))
        let latest = try #require(ISO8601DateFormatter().date(from: "2026-10-12T01:25:00Z"))
        let hrrr = IEMHRRR.frames(initTime: initTime, after: latest)
        let hour = try #require(IEMMRMS.frame(.rain1h, now: latest))
        let day = try #require(IEMMRMS.frame(.rain24h, now: latest))
        #expect(!composite.isEmpty && !hrrr.isEmpty)
        let untouched = composite + hrrr + [hour, day]
        for n in 0...10 {
            let q = Double(n) / 10
            let out = RadarSmoothing.applying(untouched, q: q)
            #expect(out.map(\.urlTemplate) == untouched.map(\.urlTemplate))
            #expect(RadarSmoothing.displayFilter(q: q, frame: hrrr[0], layer: .reflectivity) == .smooth)
            #expect(RadarSmoothing.displayFilter(q: q, frame: hour, layer: .rain1h) == .smooth)
            #expect(RadarSmoothing.displayFilter(q: q, frame: day, layer: .rain24h) == .smooth)
            #expect(RadarSmoothing.displayFilter(q: q, frame: composite[0], layer: .reflectivity) == (n == 0 ? .raw : .smooth))
        }
        #expect(RainViewerParser.applying(composite, q: 0).map(\.urlTemplate) == composite.map(\.urlTemplate))
    }

    /// A refresh fetched at another notch retags to the live `q` before the id compare, so it is not a new set.
    @Test func sameLevelRefreshIsNotANewSet() {
        let smooth = siteFrames
        let current = RadarSmoothing.retag(smooth, q: 0.6)
        let fetchedAtOtherLevel = RadarSmoothing.retag(smooth, q: 0.4)
        let update = RadarSmoothing.indexUpdate(current: current, fetched: fetchedAtOtherLevel, q: 0.6,
                                                index: 2, isPlaying: true)
        #expect(update == .unchanged)
        let untagged = RadarSmoothing.indexUpdate(current: current, fetched: smooth, q: 0.6, index: 2, isPlaying: true)
        #expect(untagged == .unchanged)
    }

    @Test func newestUpgradeKeepsPositionAndMaskedResets() throws {
        let smooth = siteFrames
        let pending = IEMRidge.newestBlocky(smooth, site: "OKX")
        let current = RadarSmoothing.retag(pending, q: 0.4)
        let adjusted = RadarSmoothing.applying(smooth, q: 0.4)
        #expect(IEMRidge.isNewestUpgrade(from: pending, to: smooth))
        #expect(IEMRidge.isNewestUpgrade(from: current, to: adjusted))
        let newest = try #require(pending.last)
        #expect(adjusted.last?.urlTemplate.hasPrefix(newest.urlTemplate) == true)

        let update = RadarSmoothing.indexUpdate(current: current, fetched: smooth, q: 0.4,
                                                index: current.count - 1, isPlaying: true)
        guard case .upgrade(let frames) = update else {
            Issue.record("unmasked blocky → smooth must stay an in-place upgrade")
            return
        }
        let loop = RadarLoopState(frames: current, index: current.count - 1, progress: 1)
        let kept = RadarLoopState(frames: frames, index: loop.index, progress: loop.progress)
        #expect(kept.index == loop.index && kept.progress == 1)

        let last = try #require(scans.last)
        let pendingMasked = RadarQC.masked(pending, latestMask: last)
        let smoothMasked = RadarQC.masked(smooth, latestMask: last)
        #expect(IEMRidge.isNewestUpgrade(from: pendingMasked, to: smoothMasked) == false)
        #expect(IEMRidge.isNewestUpgrade(from: pendingMasked, to: RadarSmoothing.retag(smoothMasked, q: 0.4)) == false)
        let masked = RadarSmoothing.indexUpdate(current: pendingMasked, fetched: smoothMasked, q: 0.4,
                                                index: 1, isPlaying: true)
        guard case .reset = masked else {
            Issue.record("masked blocky → smooth resets, matching the untagged base")
            return
        }
    }

    @Test func playingThroughANewScanKeepsIndex() throws {
        let current = siteFrames
        let laterScans = scans + [t0.addingTimeInterval(12 * 300)]
        let later = IEMRidge.frames(site: "OKX", scans: laterScans, range: .oneHour)
        #expect(current.map(\.time) != later.map(\.time))
        let playing = RadarSmoothing.indexUpdate(current: current, fetched: later, q: 0, index: 1, isPlaying: true)
        guard case .reset(_, let stayed) = playing else {
            Issue.record("a new scan is a reset, not an upgrade")
            return
        }
        #expect(stayed == 1)
        let paused = RadarSmoothing.indexUpdate(current: current, fetched: later, q: 0, index: 1, isPlaying: false)
        guard case .reset(_, let jumped) = paused else {
            Issue.record("paused must jump to now")
            return
        }
        #expect(jumped == later.count - 1)
        let first = RadarSmoothing.indexUpdate(current: [], fetched: current, q: 0, index: 0, isPlaying: true)
        guard case .reset(_, let now) = first else {
            Issue.record("empty loop jumps to now")
            return
        }
        #expect(now == current.count - 1)
    }

    @Test func withSmoothingKeepsIndexAndProgress() throws {
        let state = RadarLoopState(frames: siteFrames, index: 3, progress: 0.98)
        let next = state.withSmoothing(0)
        #expect(next.index == 3 && next.progress == 0.98)
        #expect(next.frames.map(\.time) == state.frames.map(\.time))
        #expect(next.frames.map(\.isForecast) == state.frames.map(\.isForecast))
        #expect(next.frames.map(\.id) != state.frames.map(\.id))
        #expect(next.withSmoothing(0).frames.map(\.id) == next.frames.map(\.id))

        let composite = IEMNexrad.frames(latest: t0, range: .oneHour)
        let loop = RadarLoopState(frames: composite, index: 2, progress: 1)
        #expect(loop.withSmoothing(0) == loop)
        #expect(loop.withSmoothing(1) == loop)

        let base = try RainViewerParser.decode(try Fixture.data("rainviewer"))
        let rain = RadarLoopState(frames: base, index: 5, progress: 0.99)
        let raw = rain.withSmoothing(0)
        #expect(raw.index == 5 && raw.progress == 0.99)
        #expect(raw.frames.allSatisfy { $0.urlTemplate.hasSuffix("/2/0_1.png") })
        let refresh = RadarSmoothing.indexUpdate(current: raw.frames, fetched: base, q: 0, index: 5, isPlaying: true)
        #expect(refresh == .unchanged)
    }

    @Test func rainViewerBoundary() throws {
        let fixture = try RainViewerParser.decode(try Fixture.data("rainviewer"))
        #expect(fixture.allSatisfy { $0.urlTemplate.hasSuffix("/2/1_1.png") })
        #expect(RainViewerParser.applying(fixture, q: 1).map(\.urlTemplate) == fixture.map(\.urlTemplate))
        let json = #"{"host":"https://tilecache.rainviewer.com","radar":{"past":[{"time":100,"path":"/a"}],"nowcast":[{"time":700,"path":"/b"}]}}"#
        let base = try RainViewerParser.decode(Data(json.utf8))
        #expect(base.allSatisfy { $0.urlTemplate.hasSuffix("/2/1_1.png") })
        #expect(base.map(\.isForecast) == [false, true])
        for q in [0.5, 0.9, 1.0] {
            let out = RainViewerParser.applying(base, q: q)
            #expect(out.map(\.urlTemplate) == base.map(\.urlTemplate))
            #expect(out.map(\.time) == base.map(\.time))
            #expect(out.map(\.isForecast) == base.map(\.isForecast))
        }
        let raw = RainViewerParser.applying(base, q: 0)
        let justUnder = RainViewerParser.applying(base, q: 0.49)
        #expect(raw.map(\.urlTemplate) == justUnder.map(\.urlTemplate))
        #expect(raw.allSatisfy { $0.urlTemplate.hasSuffix("/2/0_1.png") })
        #expect(raw.map(\.isForecast) == base.map(\.isForecast))
        #expect(RainViewerParser.applying(raw, q: 0).map(\.urlTemplate) == raw.map(\.urlTemplate))
        #expect(RainViewerParser.applying(raw, q: 0.5).map(\.urlTemplate) == base.map(\.urlTemplate))
        #expect(RadarSmoothing.displayFilter(q: 0, frame: raw[0], layer: .reflectivity) == .raw)
        #expect(RadarSmoothing.displayFilter(q: 0, frame: try #require(raw.last), layer: .reflectivity) == .raw)
        #expect(RadarSmoothing.displayFilter(q: 0.1, frame: raw[0], layer: .reflectivity) == .smooth)
        #expect(RadarSmoothing.displayFilter(q: 1, frame: base[0], layer: .reflectivity) == .smooth)
    }

    @Test func displayFilterPerSource() throws {
        let local = siteFrames[0]
        let blocky = try #require(IEMRidge.newestBlocky(siteFrames, site: "OKX").last)
        let composite = IEMNexrad.frames(latest: t0, range: .oneHour)[0]
        #expect(composite.urlTemplate.contains("ridge::USCOMP-N0Q-"))
        let initTime = try #require(ISO8601DateFormatter().date(from: "2026-10-11T23:00:00Z"))
        let latest = try #require(ISO8601DateFormatter().date(from: "2026-10-12T01:25:00Z"))
        let hrrr = try #require(IEMHRRR.frames(initTime: initTime, after: latest).first)
        for frame in [local, blocky, composite] {
            #expect(RadarSmoothing.displayFilter(q: 0, frame: frame, layer: .reflectivity) == .raw)
            #expect(RadarSmoothing.displayFilter(q: 0.1, frame: frame, layer: .reflectivity) == .smooth)
            #expect(RadarSmoothing.displayFilter(q: 1, frame: frame, layer: .reflectivity) == .smooth)
        }
        for q in stride(from: 0.0, through: 1, by: 0.1) {
            #expect(RadarSmoothing.displayFilter(q: q, frame: hrrr, layer: .reflectivity) == .smooth)
        }
    }

    @Test func rawSampleAndFullSmoothIdentity() {
        let ramp = raster([100, 140], width: 2, height: 1)
        #expect(ramp.sample(lon: 0, lat: 0, t: 0) == 100)
        #expect(ramp.sample(lon: 0.5, lat: 0, t: 0) == 140)
        #expect(ramp.sample(lon: 0.5, lat: 0, t: 0.5) == 130)
        #expect(ramp.sample(lon: 0.9, lat: 0, t: 0) == 140)
        #expect(ramp.sample(lon: 0.9, lat: 0, t: 0.5) == 140)
        #expect(ramp.sample(lon: 0.9, lat: 0, t: 1) == 140)
        #expect(ramp.sample(lon: 0.5, lat: 0, t: 1) == 120)
        #expect(ramp.sample(lon: 0.5, lat: 0) == ramp.sample(lon: 0.5, lat: 0, t: 1))

        let hard = raster([140, 0], width: 2, height: 1)
        #expect(hard.sample(lon: 0.49, lat: 0, t: 0) == 140)
        #expect(hard.sample(lon: 0.5, lat: 0, t: 0) == nil)

        let edge = raster([100, 0], width: 2, height: 1)
        #expect(edge.sampleEcho(lon: 0.4, lat: 0, t: 0)?.cover == 1)
        let mid = edge.sampleEcho(lon: 0.4, lat: 0, t: 0.5)?.cover ?? -1
        let full = edge.sampleEcho(lon: 0.4, lat: 0, t: 1)?.cover ?? -1
        #expect(abs(mid - 0.8) < 1e-9)
        #expect(abs(full - 0.6) < 1e-9)
    }

    /// R3-5: one footprint on [0, 0.5) and another on [0.5, 1]. The two sets are not nested.
    @Test func footprintTwoRegimes() {
        let single = raster([140, 0, 0, 0], width: 2, height: 2)
        let raw = footprint(single, 0)
        let full = footprint(single, 1)
        for t in [0.0, 0.1, 0.4, 0.49] { #expect(footprint(single, t) == raw) }
        for t in [0.5, 0.6, 0.9, 1.0] { #expect(footprint(single, t) == full) }
        #expect(raw != full)
        #expect(raw.contains("8,8"))
        #expect(!full.contains("8,8"))

        let diagonal = raster([0, 140, 140, 0], width: 2, height: 2)
        let rawDiag = footprint(diagonal, 0)
        let fullDiag = footprint(diagonal, 1)
        #expect(footprint(diagonal, 0.49) == rawDiag)
        #expect(footprint(diagonal, 0.5) == fullDiag)
        #expect(footprint(diagonal, 1) == fullDiag)
        #expect(rawDiag != fullDiag)
        #expect(!rawDiag.contains("10,10"))
        #expect(fullDiag.contains("10,10"))
    }

    private func raster(_ indices: [UInt8], width: Int, height: Int) -> RidgeRaster {
        RidgeRaster(width: width, height: height, indices: indices,
                    palette: (0..<256).map { (UInt8($0), 0, 0) },
                    lon0: 0, lat0: 0, dLon: 1, dLat: 1)
    }

    private func footprint(_ raster: RidgeRaster, _ t: Double) -> Set<String> {
        var drawn = Set<String>()
        for i in -2...24 {
            for j in -2...24 where raster.sample(lon: Double(i) / 20, lat: Double(j) / 20, t: t) != nil {
                drawn.insert("\(i),\(j)")
            }
        }
        return drawn
    }
}
