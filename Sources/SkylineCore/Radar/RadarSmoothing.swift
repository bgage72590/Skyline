import Foundation

/// How smooth already-fetched radar looks. New key `radarSmoothing.v1` (nothing migrates).
/// 0 is Raw, 1 is today's full smooth. The slider steps by 0.1, and tiles are rendered at that
/// quantized `q` — never at a live in-between value.
///
/// Local single-site N0B carries `q` in the fragment (`#raw=…&sm=N&qc=…`), which is never sent to
/// the server. The national composite and a site that fell back to it change no URLs: only the
/// display filter, and only at 0. RainViewer flips `0_1` / `1_1` in the path. HRRR and MRMS totals
/// stay on today's smooth path at every `q`.
public enum RadarSmoothing {
    public static let key = "radarSmoothing.v1"
    public static let defaultValue = 0.0
    public static let range: ClosedRange<Double> = 0...1
    public static let step = 0.1
    /// Slider drags wait this long after the last notch before any frame is rebuilt (80…100 ms).
    public static let debounceMilliseconds = 90
    public static let accessibilityLabel = "Radar smoothing"
    /// Shown as the slider's help, including the composite's two looks.
    public static let help = "Raw → Smooth (local radar and RainViewer). National composite: Raw at 0, smooth above 0."

    /// `.smooth` is today's pair: `CGContext` interpolation `.medium` and layer magnification `.linear`.
    /// `.raw` is `.none` / `.nearest`, and the context uses it only while that tile is magnified.
    /// Minification stays `.linear` at every `q`.
    public enum DisplayFilter: Equatable, Sendable {
        case raw
        case smooth
    }

    /// Clamp into `0...1`, then snap to the nearest tenth (11 levels). Non-finite values are Raw.
    public static func quantize(_ t: Double) -> Double {
        guard t.isFinite else { return defaultValue }
        let clamped = min(range.upperBound, max(range.lowerBound, t))
        return (clamped * 10).rounded() / 10
    }

    /// `N` in `&sm=N` (0…10). `q` is quantized first.
    public static func stepIndex(_ q: Double) -> Int {
        Int((quantize(q) * 10).rounded())
    }

    /// Stored level, quantized and clamped. Missing key → Raw. Does not write.
    public static func stored(in defaults: UserDefaults = .standard) -> Double {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return quantize(defaults.double(forKey: key))
    }

    /// VoiceOver value: "Raw", "Smooth", or "N%".
    public static func accessibilityValue(_ q: Double) -> String {
        let level = quantize(q)
        if level <= 0 { return "Raw" }
        if level >= 1 { return "Smooth" }
        return "\(Int((level * 100).rounded()))%"
    }

    /// The slider is for reflectivity (local N0B, national composite, RainViewer). Rain totals hide it.
    public static func showsControl(for layer: RadarLayer) -> Bool {
        !layer.isRainfallTotal
    }

    /// Per committed frame. Raw only at `q == 0`, and only for observed N0B / N0Q (including the
    /// blocky newest tile and a site that fell back to the composite) and RainViewer. HRRR (`hrrr::`)
    /// and MRMS totals stay smooth at every `q`, so a forecast frame in a Raw loop is not blocky.
    public static func displayFilter(q: Double, frame: RadarFrame, layer: RadarLayer) -> DisplayFilter {
        if layer.isRainfallTotal || frame.urlTemplate.contains("hrrr::") { return .smooth }
        let observedRidge = !frame.isForecast && frame.urlTemplate.contains("ridge::")
        guard observedRidge || RainViewerParser.isTemplate(frame.urlTemplate) else { return .smooth }
        return stepIndex(q) == 0 ? .raw : .smooth
    }

    /// Sets or replaces `&sm=N` on `#raw=` frames only, immediately after the raster base and before
    /// any `&qc=`. Blocky newest tiles, forecasts, composite, MRMS and RainViewer are byte-identical.
    /// `time` and `isForecast` are unchanged. Idempotent at the same `q`.
    public static func retag(_ frames: [RadarFrame], q: Double) -> [RadarFrame] {
        let sm = "&sm=\(stepIndex(q))"
        return frames.map { frame in
            guard let hash = frame.urlTemplate.firstIndex(of: "#"),
                  frame.urlTemplate.contains("#raw=") else { return frame }
            let base = String(frame.urlTemplate[..<hash])
            let fragment = frame.urlTemplate[frame.urlTemplate.index(after: hash)...]
            var raw: String?
            var qc: String?
            var extra: [String] = []
            for part in fragment.split(separator: "&", omittingEmptySubsequences: false) {
                let piece = String(part)
                guard let eq = piece.firstIndex(of: "=") else { extra.append(piece); continue }
                let key = String(piece[..<eq])
                let value = String(piece[piece.index(after: eq)...])
                switch key {
                case "raw": raw = value
                case "qc": qc = value
                case "sm": break
                default: extra.append(piece)
                }
            }
            guard let raw else { return frame }
            var rebuilt = base + "#raw=" + raw + sm
            if let qc { rebuilt += "&qc=" + qc }
            if !extra.isEmpty { rebuilt += "&" + extra.joined(separator: "&") }
            guard rebuilt != frame.urlTemplate else { return frame }
            var copy = frame
            copy.urlTemplate = rebuilt
            return copy
        }
    }

    /// Retag local rasters and flip RainViewer together. Everything else is left as it is.
    /// `q` is quantized first so `&sm=` and the RainViewer option stay on the same notch.
    /// `RainViewerParser.applying` itself does not quantize, so a caller can still pin 0.49 against 0.5.
    public static func applying(_ frames: [RadarFrame], q: Double) -> [RadarFrame] {
        let level = quantize(q)
        return RainViewerParser.applying(retag(frames, q: level), q: level)
    }

    /// How `loadFrames` folds a fetched index into the loop. `q` is applied **before** the upgrade
    /// check and the id compare, so a refresh at the same level is not a new set.
    public static func indexUpdate(current: [RadarFrame], fetched: [RadarFrame], q: Double, index: Int, isPlaying: Bool) -> RadarIndexUpdate {
        let adjusted = applying(fetched, q: q)
        if IEMRidge.isNewestUpgrade(from: current, to: adjusted) {
            return .upgrade(frames: adjusted)
        }
        if adjusted.map(\.id) == current.map(\.id) { return .unchanged }
        let oldNow = current.lastIndex { !$0.isForecast } ?? max(0, current.count - 1)
        let wasAtNow = !current.isEmpty && index >= oldNow
        let newNow = adjusted.lastIndex { !$0.isForecast } ?? max(0, adjusted.count - 1)
        var next = index
        if current.isEmpty || wasAtNow || !isPlaying { next = newNow }
        next = min(next, max(0, adjusted.count - 1))
        return .reset(frames: adjusted, index: next)
    }
}

/// Result of integrating a fetched frame index. `.upgrade` and `.unchanged` keep index and progress.
public enum RadarIndexUpdate: Equatable, Sendable {
    case unchanged
    case upgrade(frames: [RadarFrame])
    case reset(frames: [RadarFrame], index: Int)
}

/// Loop position plus the frames it is playing. Smoothing replaces URLs and leaves the position.
public struct RadarLoopState: Equatable, Sendable {
    public var frames: [RadarFrame]
    public var index: Int
    public var progress: Double

    public init(frames: [RadarFrame], index: Int, progress: Double) {
        self.frames = frames
        self.index = index
        self.progress = progress
    }

    /// In-place smoothing. Index and progress are not reset and the frame index is not reloaded.
    public func withSmoothing(_ q: Double) -> RadarLoopState {
        var copy = self
        copy.frames = RadarSmoothing.applying(frames, q: q)
        return copy
    }
}
