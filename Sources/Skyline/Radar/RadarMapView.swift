import AppKit
import CoreImage
import MapKit
import QuartzCore
import SwiftUI
import SkylineCore

/// MapKit base map + a Core Animation radar layer stack on top.
///
/// Threading/layout rules (the cause of the 70dfb90 crash was breaking them):
/// * Nothing in `updateNSView`, `layout()` or MKMapView delegate callbacks writes observed SwiftUI state
///   synchronously. Tile-load progress is coalesced and delivered on the next main-queue turn, and only
///   when it actually changed.
/// * The map's region/size never goes into SwiftUI state.
/// * Frame changes come straight from `RadarPlayback` to the layer view (CALayer opacity), not through
///   SwiftUI, so playing the loop never re-renders or re-lays-out SwiftUI views around the map.
/// * No NSHostingView inside the map (the pin is plain CALayers), so moving the pin can't invalidate
///   constraints mid-layout.
struct RadarMapView: NSViewRepresentable {
    let playback: RadarPlayback
    var center: Coordinate
    var frames: [RadarFrame]
    var maxNativeZoom: Int
    var interactive: Bool
    var spanDegrees: Double
    var opacity: Double
    var pinText: String?
    /// true: shows the playback's current frame (and prefetches every frame);
    /// false: pinned to the newest frame (only that frame is loaded).
    var followsPlayback: Bool
    /// Only one map at a time reports prefetch progress to the playback.
    var reportsProgress: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> RadarMapContainer {
        let container = RadarMapContainer(interactive: interactive)
        container.map.delegate = context.coordinator
        context.coordinator.container = container
        context.coordinator.recenter(on: center, span: spanDegrees)
        apply(to: container, coordinator: context.coordinator)
        return container
    }

    func updateNSView(_ container: RadarMapContainer, context: Context) {
        let c = context.coordinator
        if c.center != center { c.recenter(on: center, span: spanDegrees) }
        apply(to: container, coordinator: c)
    }

    private func apply(to container: RadarMapContainer, coordinator c: Coordinator) {
        container.pin.text = pinText
        let radar = container.radar
        radar.connect(playback: playback, follows: followsPlayback, reportsProgress: reportsProgress)
        radar.setFrames(frames, maxZ: maxNativeZoom)
        radar.setOpacity(Float(opacity))
        if interactive {
            playback.debugZoomHandler = { [weak c] factor in c?.zoom(by: factor) }
        }
    }

    static func dismantleNSView(_ container: RadarMapContainer, coordinator: Coordinator) {
        container.map.delegate = nil
        container.radar.disconnect()
    }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate {
        weak var container: RadarMapContainer?
        var center: Coordinate?

        func recenter(on c: Coordinate, span: Double) {
            guard let container else { return }
            center = c
            let coordinate = CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude)
            container.map.setRegion(MKCoordinateRegion(center: coordinate,
                                                       span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span * 1.3)),
                                    animated: false)
            container.pinCoordinate = coordinate
            container.needsLayout = true
        }

        /// QA/stress hook: zoom in (factor < 1) or out (> 1) around the current centre.
        func zoom(by factor: Double) {
            guard let map = container?.map else { return }
            var region = map.region
            region.span.latitudeDelta = min(max(region.span.latitudeDelta * factor, 0.2), 60)
            region.span.longitudeDelta = min(max(region.span.longitudeDelta * factor, 0.26), 80)
            map.setRegion(region, animated: true)
        }

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            // Continuous during gestures: reposition layers only, keep the zoom level (no tile churn).
            container?.regionChanged(settled: false)
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            container?.regionChanged(settled: true)
        }
    }
}

/// Hosts the map, the radar layers and the pin at the same frame. Pure AppKit/CA: no SwiftUI inside.
final class RadarMapContainer: NSView {
    let map = MKMapView()
    let radar = RadarLayerView()
    let pin = PinView()
    var pinCoordinate: CLLocationCoordinate2D?

    init(interactive: Bool) {
        super.init(frame: .zero)
        // Dark, muted base map: roads, coastlines and labels stay legible through a ~70 % radar layer.
        map.appearance = NSAppearance(named: .darkAqua)
        let config = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        config.pointOfInterestFilter = .excludingAll
        map.preferredConfiguration = config
        map.isZoomEnabled = interactive
        map.isScrollEnabled = interactive
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        map.showsCompass = false
        map.showsZoomControls = false
        map.showsScale = false
        if interactive {
            // Keep Apple Maps' legal attribution clear of the timeline bar.
            map.additionalSafeAreaInsets = NSEdgeInsets(top: 0, left: 0, bottom: 84, right: 0)
        }
        addSubview(map)
        addSubview(radar)
        addSubview(pin)
        radar.map = map
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        map.frame = bounds
        radar.frame = bounds
        radar.updateTiles(allowZoomChange: true)
        layoutPin()
    }

    func regionChanged(settled: Bool) {
        radar.updateTiles(allowZoomChange: settled)
        layoutPin()
    }

    private func layoutPin() {
        guard let pinCoordinate, bounds.width > 0 else { pin.isHidden = true; return }
        let point = map.convert(pinCoordinate, toPointTo: self)
        let size = pin.preferredSize
        pin.isHidden = !bounds.insetBy(dx: -size.width, dy: -size.height).contains(point)
        // Bottom dot sits on the coordinate (this view is not flipped: y grows upward).
        let frame = CGRect(x: (point.x - size.width / 2).rounded(), y: (point.y - 4).rounded(),
                           width: size.width, height: size.height)
        if pin.frame != frame { pin.frame = frame }
    }
}

/// Temperature bubble marking the forecast location (like Apple Weather's pin), drawn with CALayers.
final class PinView: NSView {
    private let bubble = CALayer()
    private let label = CATextLayer()
    private let dot = CALayer()
    private static let font = NSFont.systemFont(ofSize: 13, weight: .semibold)

    var text: String? {
        didSet { if text != oldValue { relayoutLayers() } }
    }

    private(set) var preferredSize = CGSize(width: 34, height: 36)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let noActions: [String: any CAAction] = ["bounds": NSNull(), "position": NSNull(), "contents": NSNull(), "string": NSNull()]
        bubble.backgroundColor = NSColor(calibratedRed: 0.13, green: 0.42, blue: 0.95, alpha: 1).cgColor
        bubble.borderColor = NSColor.white.cgColor
        bubble.borderWidth = 2
        bubble.shadowOpacity = 0.35
        bubble.shadowRadius = 3
        bubble.shadowOffset = CGSize(width: 0, height: -1)
        bubble.actions = noActions
        label.font = Self.font
        label.fontSize = 13
        label.foregroundColor = NSColor.white.cgColor
        label.alignmentMode = .center
        label.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        label.actions = noActions
        dot.backgroundColor = NSColor.white.cgColor
        dot.cornerRadius = 3.5
        dot.actions = noActions
        layer?.addSublayer(dot)
        layer?.addSublayer(bubble)
        bubble.addSublayer(label)
        relayoutLayers()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func relayoutLayers() {
        let string = text ?? "•"
        let textWidth = ceil((string as NSString).size(withAttributes: [.font: Self.font]).width)
        let bubbleSize = CGSize(width: max(32, textWidth + 16), height: 26)
        preferredSize = CGSize(width: bubbleSize.width, height: bubbleSize.height + 10)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.frame = CGRect(x: bubbleSize.width / 2 - 3.5, y: 0, width: 7, height: 7)
        bubble.frame = CGRect(x: 0, y: 10, width: bubbleSize.width, height: bubbleSize.height)
        bubble.cornerRadius = bubbleSize.height / 2
        label.string = string
        label.frame = CGRect(x: 0, y: (bubbleSize.height - 17) / 2, width: bubbleSize.width, height: 17)
        CATransaction.commit()
    }
}

/// Transparent, click-through view holding one CALayer per radar frame.
final class RadarLayerView: NSView {
    weak var map: MKMapView?

    /// Each map may hold at most this many decoded tiles (≈256 KB each → ~40 MB, plus its GPU copy).
    static let tileBudget = 160

    /// One prefetched set of frames. A new set (fresh scans) is built hidden as `pending` and only
    /// swapped in once its tiles are loaded, so the radar never blanks.
    private final class Generation {
        let frames: [RadarFrame]
        let root = CALayer()
        var frameLayers: [CALayer] = []
        var tiles: [[TileKey: CALayer]]
        var requested: [Set<TileKey>]
        var missing: [Set<TileKey>]

        init(frames: [RadarFrame], bounds: CGRect) {
            self.frames = frames
            tiles = Array(repeating: [:], count: frames.count)
            requested = Array(repeating: [], count: frames.count)
            missing = Array(repeating: [], count: frames.count)
            root.frame = bounds
            root.actions = Self.noActions
            for _ in frames {
                let layer = CALayer()
                layer.frame = bounds
                layer.opacity = 0
                layer.actions = ["bounds": NSNull(), "position": NSNull(), "sublayers": NSNull()]
                root.addSublayer(layer)
                frameLayers.append(layer)
            }
        }

        static let noActions: [String: any CAAction] = [
            "bounds": NSNull(), "position": NSNull(), "contents": NSNull(), "opacity": NSNull(),
            "sublayers": NSNull(), "onOrderIn": NSNull(), "onOrderOut": NSNull(),
        ]

        func isComplete(_ i: Int, desired: [TileKey]) -> Bool {
            guard tiles.indices.contains(i) else { return true }
            return desired.allSatisfy { tiles[i][$0] != nil || missing[i].contains($0) }
        }
    }

    private var active: Generation?
    private var pending: Generation?
    private var maxZ = 7
    private var zoom = 0
    private var desired: [TileKey] = []
    private var keep: Set<TileKey> = []
    private var index = 0
    private var opacity: Float = 0.7

    private weak var playback: RadarPlayback?
    private var follows = true
    private var reportsProgress = false
    private var progressScheduled = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        // Screen-blend the radar over the dark base map: white labels, roads and coastlines can't be
        // darkened by it, so they stay legible through the radar while precipitation colours show fully.
        layer?.compositingFilter = CIFilter(name: "CIScreenBlendMode")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // MARK: Playback connection

    func connect(playback p: RadarPlayback, follows f: Bool, reportsProgress r: Bool) {
        if playback !== p {
            playback?.removeSink(self)
            playback = p
        }
        reportsProgress = r
        if f != follows || playback == nil {
            follows = f
        }
        if follows { p.addSink(self) } else { p.removeSink(self) }
        let wanted = follows ? p.index : lastIndex
        if wanted != index {
            index = wanted
            applyVisibility(animated: false)
        }
        if r { scheduleProgressReport() }
    }

    func disconnect() {
        playback?.removeSink(self)
        playback = nil
    }

    private var lastIndex: Int { max(0, ((pending ?? active)?.frames.count ?? 1) - 1) }

    /// Called by RadarPlayback when its frame index changes (timer or scrubber) — never during layout.
    func playbackIndexChanged(_ newIndex: Int, animated: Bool) {
        guard follows, newIndex != index else { return }
        index = newIndex
        applyVisibility(animated: animated)
        if let map { request(TileMath.tiles(covering: visibleRect(map.visibleMapRect), z: zoom, margin: 1), in: active, frames: [index]) }
    }

    func setOpacity(_ value: Float) {
        guard value != opacity else { return }
        opacity = value
        applyVisibility(animated: false)
    }

    // MARK: Frames

    func setFrames(_ frames: [RadarFrame], maxZ: Int) {
        let ids = frames.map(\.id)
        if ids == (pending ?? active)?.frames.map(\.id), maxZ == self.maxZ { return }
        self.maxZ = maxZ
        let generation = Generation(frames: frames, bounds: bounds)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if active == nil || frames.isEmpty || active?.frames.isEmpty == true {
            active?.root.removeFromSuperlayer()
            pending?.root.removeFromSuperlayer()
            pending = nil
            active = generation
        } else {
            pending?.root.removeFromSuperlayer()
            generation.root.opacity = 0
            pending = generation
        }
        layer?.addSublayer(generation.root)
        CATransaction.commit()
        index = follows ? min(playback?.index ?? lastIndex, max(0, frames.count - 1)) : lastIndex
        zoom = 0
        applyVisibility(animated: false)
        updateTiles(allowZoomChange: true)
    }

    private func applyVisibility(animated: Bool) {
        guard let g = active, !g.frameLayers.isEmpty else { return }
        let shown = min(max(index, 0), g.frames.count - 1)
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(0.35)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        for (i, frameLayer) in g.frameLayers.enumerated() {
            let target: Float = i == shown ? opacity : 0
            if frameLayer.opacity != target { frameLayer.opacity = target }
        }
        CATransaction.commit()
    }

    // MARK: Tiles

    private func visibleRect(_ v: MKMapRect) -> MapRectValue {
        MapRectValue(x: v.origin.x, y: v.origin.y, width: v.size.width, height: v.size.height)
    }

    /// Frames this view needs loaded: all of them when following playback, else only the one shown.
    private func neededFrames(_ g: Generation) -> [Int] {
        guard !g.frames.isEmpty else { return [] }
        let shown = min(max(index, 0), g.frames.count - 1)
        guard follows else { return [shown] }
        var order = [shown]
        for i in g.frames.indices.reversed() where i != shown { order.append(i) } // newest → oldest
        return order
    }

    /// Recomputes the visible tile set, lays out existing tile layers and requests missing ones.
    /// Touches only CALayers and plain properties; never SwiftUI state.
    func updateTiles(allowZoomChange: Bool) {
        guard let map, bounds.width > 1, bounds.height > 1 else { return }
        let v = map.visibleMapRect
        guard v.size.width > 0 else { return }
        let visible = visibleRect(v)
        let frameCount = follows ? max((pending ?? active)?.frames.count ?? 1, 1) : 1
        let z = TileMath.zoom(fitting: visible, viewWidth: Double(bounds.width), maxZ: maxZ,
                              frames: frameCount, tileBudget: Self.tileBudget)
        if allowZoomChange || zoom == 0 { zoom = z }
        desired = TileMath.tiles(covering: visible, z: zoom, margin: 0)
        keep = Set(TileMath.tiles(covering: visible, z: zoom, margin: 1))
        layoutTiles(v)
        for g in [active, pending].compactMap({ $0 }) {
            let needed = neededFrames(g)
            // Visible frame gets a one-tile ring of prefetch; the rest only what's on screen (memory).
            if let first = needed.first { request(Array(keep), in: g, frames: [first]) }
            request(desired, in: g, frames: Array(needed.dropFirst()))
            for i in g.frames.indices { prune(g, i, needed: needed.contains(i)) }
        }
        promotePendingIfReady()
        scheduleProgressReport()
    }

    private func request(_ keys: [TileKey], in g: Generation?, frames: [Int]) {
        guard let g else { return }
        for i in frames where g.frames.indices.contains(i) {
            let frame = g.frames[i]
            for key in keys where g.tiles[i][key] == nil && !g.missing[i].contains(key) && !g.requested[i].contains(key) {
                guard let url = frame.url(z: key.z, x: key.x, y: key.y) else { continue }
                if let image = RadarImageCache.shared.image(for: url) {
                    addTile(image, key: key, frame: i, in: g)
                } else if RadarImageCache.shared.recentlyFailed(url) {
                    g.missing[i].insert(key)
                } else {
                    g.requested[i].insert(key)
                    RadarImageCache.shared.load(url, wanted: { [weak self, weak g] in
                        guard let self, let g, self.active === g || self.pending === g else { return false }
                        return key.z == self.zoom && self.neededFrames(g).contains(i)
                    }, cancelled: { [weak g] in
                        g?.requested[i].remove(key)
                    }) { [weak self, weak g] image in
                        guard let self, let g else { return }
                        g.requested[i].remove(key)
                        if let image { self.addTile(image, key: key, frame: i, in: g) } else { g.missing[i].insert(key) }
                        self.prune(g, i, needed: self.neededFrames(g).contains(i))
                        self.promotePendingIfReady()
                        self.scheduleProgressReport()
                    }
                }
            }
        }
    }

    private func addTile(_ image: CGImage, key: TileKey, frame i: Int, in g: Generation) {
        guard g.tiles[i][key] == nil, key.z == zoom, let map else { return }
        let tile = CALayer()
        tile.actions = Generation.noActions
        tile.contents = image
        tile.contentsGravity = .resize
        tile.magnificationFilter = .linear
        tile.minificationFilter = .linear
        tile.zPosition = CGFloat(key.z)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tile.frame = rect(for: key, visible: map.visibleMapRect)
        g.frameLayers[i].addSublayer(tile)
        CATransaction.commit()
        g.tiles[i][key] = tile
    }

    /// Drops tiles that scrolled away, frames this view no longer needs, and other-zoom placeholders
    /// once the current zoom is complete.
    private func prune(_ g: Generation, _ i: Int, needed: Bool) {
        let complete = g.isComplete(i, desired: desired)
        var removed: [TileKey] = []
        for (key, tile) in g.tiles[i] {
            let stale = !needed || (key.z == zoom ? !keep.contains(key) : complete)
            if stale {
                tile.removeFromSuperlayer()
                removed.append(key)
            }
        }
        if !removed.isEmpty {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for key in removed { g.tiles[i][key] = nil }
            CATransaction.commit()
        }
        g.missing[i] = g.missing[i].filter { $0.z == zoom }
    }

    private func promotePendingIfReady() {
        guard let p = pending, p.isComplete(min(index, p.frames.count - 1), desired: desired) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        active?.root.removeFromSuperlayer()
        p.root.opacity = 1
        active = p
        pending = nil
        CATransaction.commit()
        applyVisibility(animated: false)
    }

    /// Coalesced and deferred: progress is computed and handed to SwiftUI on the next main-queue turn,
    /// outside any layout or view-update pass. `RadarPlayback` drops unchanged values.
    private func scheduleProgressReport() {
        guard reportsProgress, !progressScheduled else { return }
        progressScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.progressScheduled = false
            guard self.reportsProgress, let playback = self.playback else { return }
            playback.reportProgress(self.currentProgress())
        }
    }

    private func currentProgress() -> Double {
        guard let g = pending ?? active, !g.frames.isEmpty, !desired.isEmpty else { return 0 }
        let needed = neededFrames(g)
        var resolved = 0
        for i in needed {
            resolved += desired.reduce(0) { $0 + ((g.tiles[i][$1] != nil || g.missing[i].contains($1)) ? 1 : 0) }
        }
        return Double(resolved) / Double(needed.count * desired.count)
    }

    private func layoutTiles(_ v: MKMapRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for g in [active, pending].compactMap({ $0 }) {
            if g.root.frame != bounds { g.root.frame = bounds }
            for (i, frameLayer) in g.frameLayers.enumerated() {
                if frameLayer.frame != bounds { frameLayer.frame = bounds }
                for (key, tile) in g.tiles[i] { tile.frame = rect(for: key, visible: v) }
            }
        }
        CATransaction.commit()
    }

    /// Tile rect in this (non-flipped, bottom-left origin) view.
    private func rect(for key: TileKey, visible v: MKMapRect) -> CGRect {
        let r = TileMath.rect(key)
        let scale = Double(bounds.width) / v.size.width
        let x = (r.x - v.origin.x) * scale
        let yTop = (r.y - v.origin.y) * scale
        let size = r.width * scale
        return CGRect(x: x, y: Double(bounds.height) - yTop - size, width: size, height: size)
    }
}
