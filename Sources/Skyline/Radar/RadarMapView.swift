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
    /// NWS alert outlines drawn above the radar (CAShapeLayers, repositioned with the map).
    var alerts: [WeatherAlert] = []
    /// When this changes to an alert with an outline, the map frames that outline.
    var focusedAlertID: String?
    /// Points of the map hidden (clipped) on each side; keeps MapKit's legal label and alert framing
    /// inside the visible part.
    var horizontalOverscan: CGFloat = 0

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
        container.setOverscan(horizontalOverscan)
        container.alertOverlay.setAlerts(alerts.map { AlertOverlayView.Shape(alert: $0) }, focused: focusedAlertID)
        if focusedAlertID != c.lastFocusedAlertID {
            c.lastFocusedAlertID = focusedAlertID
            if let id = focusedAlertID, let alert = alerts.first(where: { $0.id == id }), !alert.polygons.isEmpty {
                // Deferred: never move the map (→ delegate callbacks → layer layout) inside a SwiftUI update.
                let rings = alert.polygons
                DispatchQueue.main.async { [weak c] in c?.frame(rings) }
            }
        }
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
        var lastFocusedAlertID: String?

        /// Zooms the map to fit an alert outline.
        func frame(_ rings: [[Coordinate]]) {
            guard let map = container?.map else { return }
            var rect = MKMapRect.null
            for ring in rings {
                for c in ring {
                    let p = MKMapPoint(CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude))
                    rect = rect.union(MKMapRect(x: p.x, y: p.y, width: 0, height: 0))
                }
            }
            guard !rect.isNull else { return }
            let minSide = 60_000.0 // keep some context around tiny storm polygons
            if rect.size.width < minSide { rect = rect.insetBy(dx: -(minSide - rect.size.width) / 2, dy: 0) }
            if rect.size.height < minSide { rect = rect.insetBy(dx: 0, dy: -(minSide - rect.size.height) / 2) }
            let side = 60 + (container?.overscan ?? 0)
            map.setVisibleMapRect(rect, edgePadding: NSEdgeInsets(top: 90, left: side, bottom: 140, right: side), animated: true)
        }

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
            region.span.latitudeDelta = min(max(region.span.latitudeDelta * factor, RadarZoomLimits.minSpan), RadarZoomLimits.maxSpan)
            region.span.longitudeDelta = min(max(region.span.longitudeDelta * factor, RadarZoomLimits.minSpan * 1.3), RadarZoomLimits.maxSpan * 1.3)
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
enum RadarZoomLimits {
    static let minCameraDistance: CLLocationDistance = 60_000      // ~25 km across: a metro area
    static let maxCameraDistance: CLLocationDistance = 6_000_000   // ~2,500 km across
    static let minSpan = 0.5, maxSpan = 30.0                        // degrees latitude, for programmatic zoom
}

final class RadarMapContainer: NSView {
    /// Live instance / tile-layer counts, for the stress test's memory log (main thread only).
    nonisolated(unsafe) static var live = 0
    let map = MKMapView()
    let radar = RadarLayerView()
    let alertOverlay = AlertOverlayView()
    let pin = PinView()
    var pinCoordinate: CLLocationCoordinate2D?

    init(interactive: Bool) {
        super.init(frame: .zero)
        Self.live += 1
        // Dark, muted base map: roads, coastlines and labels stay legible through a ~70 % radar layer.
        map.appearance = NSAppearance(named: .darkAqua)
        let config = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        config.pointOfInterestFilter = .excludingAll
        map.preferredConfiguration = config
        // Radar is meaningless at street level (NEXRAD's finest tiles are ~1 km) and MapKit's vector
        // data for dense street-level and continent-wide views is the app's biggest memory cost, so
        // keep the camera between "metro area" and "half a continent".
        map.cameraZoomRange = MKMapView.CameraZoomRange(minCenterCoordinateDistance: RadarZoomLimits.minCameraDistance,
                                                        maxCenterCoordinateDistance: RadarZoomLimits.maxCameraDistance)
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
        addSubview(alertOverlay)
        addSubview(pin)
        radar.map = map
        alertOverlay.map = map
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { Self.live -= 1 }

    private(set) var overscan: CGFloat = 0
    /// Moves MapKit's own chrome (legal label) out of the clipped margins. Deferred to the next main-queue
    /// turn: never change AppKit layout inputs inside a SwiftUI update pass. No-op when unchanged.
    func setOverscan(_ value: CGFloat) {
        guard value != overscan else { return }
        overscan = value
        DispatchQueue.main.async { [weak self] in
            guard let self, self.overscan == value else { return }
            self.map.additionalSafeAreaInsets = NSEdgeInsets(top: 0, left: value, bottom: 0, right: value)
            self.radar.horizontalInset = value
            self.radar.updateTiles(allowZoomChange: true)
        }
    }

    /// Visible card is `bounds` inset by `overscan` on each side. SwiftUI `.clipShape` only clips
    /// drawing; without this, the invisible overscan still receives trackpad scroll/zoom and pans
    /// the map while the pointer is over the forecast column.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard overscan > 0 else { return super.hitTest(point) }
        let local = convert(point, from: superview)
        let visible = bounds.insetBy(dx: overscan, dy: 0)
        guard visible.contains(local) else { return nil }
        return super.hitTest(point)
    }

    override func layout() {
        super.layout()
        map.frame = bounds
        radar.frame = bounds
        alertOverlay.frame = bounds
        radar.updateTiles(allowZoomChange: true)
        alertOverlay.relayout()
        layoutPin()
    }

    func regionChanged(settled: Bool) {
        radar.updateTiles(allowZoomChange: settled)
        alertOverlay.relayout()
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

/// NWS alert outlines (severity-coloured stroke + light fill) drawn above the radar. Pure CA:
/// paths are recomputed from the map's current projection on layout / region change.
final class AlertOverlayView: NSView {
    struct Shape: Equatable {
        let id: String
        let rings: [[Coordinate]]
        let color: CGColor

        init(alert: WeatherAlert) {
            id = alert.id
            rings = alert.polygons
            color = switch alert.severity {
            case .extreme: NSColor.systemRed.cgColor
            case .severe: NSColor.systemOrange.cgColor
            case .moderate: NSColor.systemYellow.cgColor
            case .minor, .unknown: NSColor.white.cgColor
            }
        }
        static func == (a: Shape, b: Shape) -> Bool { a.id == b.id && a.rings == b.rings }
    }

    weak var map: MKMapView?
    private var shapes: [Shape] = []
    private var focused: String?
    private var layers: [String: CAShapeLayer] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setAlerts(_ new: [Shape], focused newFocus: String?) {
        let withOutlines = new.filter { !$0.rings.isEmpty }
        guard withOutlines != shapes || newFocus != focused else { return }
        shapes = withOutlines
        focused = newFocus
        let ids = Set(shapes.map(\.id))
        for (id, l) in layers where !ids.contains(id) { l.removeFromSuperlayer(); layers[id] = nil }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for shape in shapes {
            let l = layers[shape.id] ?? {
                let l = CAShapeLayer()
                l.actions = ["path": NSNull(), "lineWidth": NSNull(), "fillColor": NSNull()]
                layer?.addSublayer(l)
                layers[shape.id] = l
                return l
            }()
            let isFocused = shape.id == focused
            l.strokeColor = shape.color
            l.fillColor = shape.color.copy(alpha: isFocused ? 0.22 : 0.10)
            l.lineWidth = isFocused ? 3 : 1.6
            l.lineJoin = .round
            l.lineDashPattern = isFocused ? nil : [6, 3]
            l.zPosition = isFocused ? 1 : 0
        }
        CATransaction.commit()
        relayout()
    }

    func relayout() {
        guard let map, bounds.width > 0, !shapes.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for shape in shapes {
            let path = CGMutablePath()
            for ring in shape.rings {
                for (i, c) in ring.enumerated() {
                    let p = map.convert(CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude), toPointTo: self)
                    if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
                }
                path.closeSubpath()
            }
            layers[shape.id]?.frame = bounds
            layers[shape.id]?.path = path
        }
        CATransaction.commit()
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
    nonisolated(unsafe) static var liveTiles = 0
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

        deinit { RadarLayerView.liveTiles -= tiles.reduce(0) { $0 + $1.count } }

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

    /// Points clipped off each side by the container's overscan; tiles there are never visible.
    var horizontalInset: CGFloat = 0

    /// The part of the map actually on screen (minus the clipped overscan), in map points.
    private func visibleRect(_ v: MKMapRect) -> MapRectValue {
        let frac = bounds.width > 1 ? min(max(Double(horizontalInset / bounds.width), 0), 0.45) : 0
        let dx = v.size.width * frac
        return MapRectValue(x: v.origin.x + dx, y: v.origin.y, width: v.size.width - 2 * dx, height: v.size.height)
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
        let z = TileMath.zoom(fitting: visible, viewWidth: Double(max(bounds.width - 2 * horizontalInset, 1)), maxZ: maxZ,
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
        Self.liveTiles += 1
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
            Self.liveTiles -= removed.count
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
