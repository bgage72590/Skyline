import AppKit
import CoreImage
import MapKit
import QuartzCore
import SwiftUI
import SkylineCore

/// MapKit base map with the radar as a MapKit overlay (build 35), alert outlines and the pin on top.
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
        SwiftUIUpdatePass.enter(); defer { SwiftUIUpdatePass.leave() }
        let container = RadarMapContainer(interactive: interactive)
        context.coordinator.container = container
        // The new map isn't in a window yet, and its delegate is attached only afterwards, so this first
        // region set fires no delegate callbacks inside the SwiftUI update.
        context.coordinator.recenter(on: center, span: spanDegrees)
        container.map.delegate = context.coordinator
        apply(to: container, coordinator: context.coordinator)
        return container
    }

    func updateNSView(_ container: RadarMapContainer, context: Context) {
        SwiftUIUpdatePass.enter(); defer { SwiftUIUpdatePass.leave() }
        let c = context.coordinator
        // L1: never move the map inside a SwiftUI update (setRegion → delegate callbacks → layer work and
        // a layout pass). Note the new centre now (no double dispatch), move on the next main-queue turn.
        if c.center != center { c.scheduleRecenter(on: center, span: spanDegrees) }
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
            playback.debugPanHandler = { [weak c] dx, dy in c?.pan(dx: dx, dy: dy) }
            playback.debugRadarStats = { [weak radar] in
                guard let radar else { return (0, 0, 0) }
                return (radar.visibleHolesInShownFrame(), radar.missingRingTiles(), radar.heldTileCount)
            }
        }
    }

    static func dismantleNSView(_ container: RadarMapContainer, coordinator: Coordinator) {
        container.map.delegate = nil
        container.radar.disconnect()
        // Menu-bar only after ⌘Q / close: hand MapKit everything back so its engine (vector tiles,
        // Metal buffers) can go. Without this a closed window's MKMapView stayed alive (F).
        container.map.removeOverlays(container.map.overlays)
        container.map.removeAnnotations(container.map.annotations)
        container.radar.removeFromSuperview()
        container.map.removeFromSuperview()
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

        /// Deferred recenter for `updateNSView`. If the location changes again before it runs, only the
        /// latest centre is applied.
        func scheduleRecenter(on c: Coordinate, span: Double) {
            center = c
            DispatchQueue.main.async { [weak self] in
                guard let self, self.center == c else { return }
                self.recenter(on: c, span: span)
            }
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

        /// Measurement hook: move the map by a fraction of the visible size, without animation.
        func pan(dx: Double, dy: Double) {
            guard let map = container?.map else { return }
            var r = map.visibleMapRect
            r.origin.x += r.size.width * dx
            r.origin.y += r.size.height * dy
            map.setVisibleMapRect(r, animated: false)
        }

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            // Continuous during gestures: MapKit moves the radar itself; only the pin/alerts follow, and
            // edge loading is coalesced (no pruning, no zoom change).
            container?.regionChanged(settled: false)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
            if let container, container.radar.isRadarOverlay(overlay) { return container.radar.makeRenderer(for: overlay) }
            return MKOverlayRenderer(overlay: overlay)
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
        // Dark base map at full emphasis (not muted): brighter roads and higher-contrast town labels read
        // through the ~60 % source-over radar layer (R1), RadarScope/MyRadar style.
        map.appearance = NSAppearance(named: .darkAqua)
        let config = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .default)
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
        addSubview(radar) // invisible tile manager; the radar itself is drawn by MapKit
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
        if radar.frame.size != bounds.size { radar.sizeWillChange() }
        radar.frame = bounds
        alertOverlay.frame = bounds
        radar.updateTiles(allowZoomChange: true)
        alertOverlay.relayout()
        layoutPin()
    }

    func regionChanged(settled: Bool) {
        if settled { radar.updateTiles(allowZoomChange: true) } else { radar.gestureMoved() }
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

/// The radar as one world-sized MapKit overlay (build 35) whose renderer paints the shown frame's
/// decoded tiles, so MapKit draws the radar in the same render pass as the base map (no lag or edge pop
/// while panning). Crossfades are Core Animation copies on top (RadarLayerView.startFade).
final class RadarOverlay: NSObject, MKOverlay {
    // Centre of the world rect (review L6); not an annotation and never geocoded.
    let coordinate = MKMapPoint(x: MKMapRect.world.midX, y: MKMapRect.world.midY).coordinate
    let boundingMapRect = MKMapRect.world
    func canReplaceMapContent() -> Bool { false }
}

/// What a renderer draws, swapped atomically from the main thread and read on MapKit's draw threads.
/// Tiles are stored already in draw order (sorted once per change, not per draw call; review M4/L5).
final class RadarDrawState: @unchecked Sendable {
    private let lock = NSLock()
    private var tiles: [(TileKey, CGImage)] = []
    /// Draw passes so far and when the last one ran (review H1: a copy is removed only after MapKit drew).
    private var draws = 0
    private var lastDrawTime: CFTimeInterval = 0
    /// Expanded (drawable RGBA) images of the frame on screen; only this frame (plus up to two
    /// expanded ahead off the main thread) is expanded, every other held frame stays packed.
    private var expanded: [TileKey: CGImage] = [:]
    private var frameToken: AnyHashable?

    /// Main thread. `token` identifies the frame (generation + index); expansions are reused within it.
    /// `prebuilt`: images already expanded in the background for this frame.
    func set(_ new: [TileKey: RadarTile], zoom: Int, token: AnyHashable, prebuilt: [TileKey: CGImage]? = nil) {
        if token != frameToken { expanded = prebuilt ?? [:]; frameToken = token }
        expanded = expanded.filter { new[$0.key] != nil }
        for (key, tile) in new where expanded[key] == nil { expanded[key] = tile.image() }
        let ordered = RadarPolicy.drawOrder(Array(expanded.keys), currentZoom: zoom).map { ($0, expanded[$0]!) }
        lock.lock(); tiles = ordered; lock.unlock()
    }
    func clear() { expanded = [:]; frameToken = nil; lock.lock(); tiles = []; lock.unlock() }
    /// What the renderer draws: always the frame on screen (never hidden since build 48).
    func snapshot() -> [(TileKey, CGImage)] { lock.lock(); defer { lock.unlock() }; return tiles }
    func drawable() -> [(TileKey, CGImage)] { snapshot() }
    /// MapKit draw threads, after each draw pass.
    func noteDraw() { lock.lock(); draws += 1; lastDrawTime = CACurrentMediaTime(); lock.unlock() }
    var drawCount: Int { lock.lock(); defer { lock.unlock() }; return draws }
    var lastDraw: CFTimeInterval { lock.lock(); defer { lock.unlock() }; return lastDrawTime }
}

final class RadarOverlayRenderer: MKOverlayRenderer {
    let state: RadarDrawState

    init(overlay: RadarOverlay, state: RadarDrawState) {
        self.state = state
        super.init(overlay: overlay)
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        let tiles = state.snapshot()
        defer { state.noteDraw() }
        guard !tiles.isEmpty else { return }
        context.interpolationQuality = .medium
        for (key, image) in tiles {
            let r = TileMath.rect(key)
            let tileRect = MKMapRect(x: r.x, y: r.y, width: r.width, height: r.height)
            guard tileRect.intersects(mapRect) else { continue }
            let cg = rect(for: tileRect)
            context.saveGState()
            // MapKit's context is y-down; CGImage draws y-up.
            context.translateBy(x: cg.minX, y: cg.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(origin: .zero, size: cg.size))
            context.restoreGState()
        }
    }
}

/// Radar tile manager: loads and holds each frame's decoded (losslessly packed) tiles and hands frames
/// to the overlay's renderer. Invisible and click-through; it only borrows the container's size.
final class RadarLayerView: NSView {
    nonisolated(unsafe) static var liveTiles = 0
    /// Tiles added since launch (measurement log: a steady loop should stop adding).
    nonisolated(unsafe) static var addedTiles = 0
    weak var map: MKMapView? {
        didSet { attachOverlays() }
    }

    /// Per-frame zoom budget. Playing never lowers the zoom (quality first).
    static let tileBudget = max(40, UserDefaults.standard.object(forKey: "SkylineTileBudget") as? Int ?? 160)

    let overlay = RadarOverlay()
    private let states = [RadarDrawState()]
    private var renderers: [RadarOverlayRenderer?] = [nil]
    /// Frame index (in `active`) on screen; may lag `index` while the target frame is still loading.
    private var shownFrame: Int?
    private var fade = RadarCrossfade(shown: 0)

    /// One prefetched set of frames. A fresh-scan set loads as `pending` (shown frame + next 3 only,
    /// while the old set keeps playing) and is swapped in once its shown frame is complete; the old set
    /// is released at the swap.
    private final class Generation {
        let frames: [RadarFrame]
        var tiles: [[TileKey: RadarTile]]
        var requested: [Set<TileKey>]
        var missing: [Set<TileKey>]

        deinit { RadarLayerView.liveTiles -= tiles.reduce(0) { $0 + $1.count } }

        init(frames: [RadarFrame]) {
            self.frames = frames
            tiles = Array(repeating: [:], count: frames.count)
            requested = Array(repeating: [], count: frames.count)
            missing = Array(repeating: [], count: frames.count)
        }

        func isComplete(_ i: Int, desired: [TileKey]) -> Bool {
            guard tiles.indices.contains(i) else { return true }
            return RadarPolicy.isShowable(have: Set(tiles[i].keys), resolved: missing[i], desired: desired)
        }
    }

    private var active: Generation?
    private var pending: Generation?
    private var maxZ = 7
    private var zoom = 0
    private var desired: [TileKey] = []
    private var keep: Set<TileKey> = []
    private var index = 0
    private var opacity: Float = Float(RadarOpacity.defaultValue)
    private var retryObserver: NSObjectProtocol?

    private weak var playback: RadarPlayback?
    private var follows = true
    private var reportsProgress = false
    private var progressScheduled = false
    private var gestureWorkScheduled = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        retryObserver = NotificationCenter.default.addObserver(forName: RadarImageCache.retryNotification, object: nil,
                                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.retryMissingTiles() }
        }
    }

    deinit {
        if let retryObserver { NotificationCenter.default.removeObserver(retryObserver) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func attachOverlays() {
        guard let map else { return }
        if !map.overlays.contains(where: { $0 === overlay }) { map.addOverlay(overlay, level: .aboveLabels) }
    }

    func isRadarOverlay(_ overlay: any MKOverlay) -> Bool { overlay === self.overlay }

    /// The map delegate asks for the overlay's renderer.
    func makeRenderer(for overlay: any MKOverlay) -> RadarOverlayRenderer {
        let r = RadarOverlayRenderer(overlay: self.overlay, state: states[0])
        r.alpha = CGFloat(opacity)
        renderers[0] = r
        return r
    }

    private func retryMissingTiles() {
        guard playback?.isVisible == true, RadarImageCache.shared.isOnline else { return }
        var changed = false
        for g in [active, pending].compactMap({ $0 }) {
            for i in g.frames.indices where !g.missing[i].isEmpty {
                let frame = g.frames[i]
                let before = g.missing[i].count
                g.missing[i] = g.missing[i].filter { key in
                    guard let url = frame.url(z: key.z, x: key.x, y: key.y) else { return true }
                    return RadarImageCache.shared.recentlyFailed(url)
                }
                if g.missing[i].count != before { changed = true }
            }
        }
        if changed { updateTiles(allowZoomChange: false) }
    }

    /// Playback started/stopped needing the whole loop. The zoom is kept (playing never drops resolution).
    func loopHoldChanged() {
        updateTiles(allowZoomChange: false)
    }

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
            showTarget(animated: false)
        }
        if r { scheduleProgressReport() }
    }

    func disconnect() {
        playback?.removeSink(self)
        playback = nil
        cancelFade()
    }

    private var lastIndex: Int { max(0, ((pending ?? active)?.frames.count ?? 1) - 1) }

    /// Called by RadarPlayback when its frame index changes (timer or scrubber) — never during layout.
    func playbackIndexChanged(_ newIndex: Int, animated: Bool) {
        guard follows, newIndex != index else { return }
        index = newIndex
        if let g = active { request(ringTiles(), in: g, frames: [shownIndex(g)]) }
        showTarget(animated: animated)
    }

    func setOpacity(_ value: Float) {
        guard value != opacity else { return }
        opacity = value
        applyAlphas()
    }

    // MARK: Frames

    func setFrames(_ frames: [RadarFrame], maxZ: Int) {
        let ids = frames.map(\.id)
        if ids == (pending ?? active)?.frames.map(\.id), maxZ == self.maxZ { return }
        self.maxZ = maxZ
        let generation = Generation(frames: frames)
        if active == nil || frames.isEmpty || active?.frames.isEmpty == true {
            pending = nil
            dropAhead()
            active = generation
            shownFrame = nil
        } else {
            pending = generation
        }
        index = follows ? min(playback?.index ?? lastIndex, max(0, frames.count - 1)) : lastIndex
        zoom = 0
        updateTiles(allowZoomChange: true)
        showTarget(animated: false)
    }

    /// Measurement hook: `-SkylineCrossfade NO` switches frames without the fade.
    static let crossfadeEnabled = UserDefaults.standard.object(forKey: "SkylineCrossfade") == nil || UserDefaults.standard.bool(forKey: "SkylineCrossfade")

    private static func token(_ g: Generation, _ i: Int) -> AnyHashable { AnyHashable([ObjectIdentifier(g).hashValue, i]) }

    private func shownIndex(_ g: Generation) -> Int { min(max(index, 0), max(g.frames.count - 1, 0)) }

    // MARK: Showing frames (crossfade, never a mix of two frames)

    /// Shows the playback's frame once every on-screen tile of it is resolved (or after
    /// `RadarPolicy.incompleteTimeout`); until then the previous frame stays on screen. Frames come
    /// expanded from a background queue; animated switches crossfade (`startFade`).
    private func showTarget(animated: Bool) {
        guard let g = active, !g.frames.isEmpty else {
            cancelFade()
            states[0].clear()
            renderers[0]?.setNeedsDisplay()
            shownFrame = nil
            return
        }
        let target = shownIndex(g)
        if target == shownFrame { waitTarget = nil; return }
        let token0 = Self.token(g, target)
        if waitTarget?.token != token0 { waitTarget = (token0, CACurrentMediaTime()) }
        guard RadarPolicy.shouldShow(complete: g.isComplete(target, desired: desired), nothingShown: shownFrame == nil,
                                     waited: CACurrentMediaTime() - waitTarget!.since) else {
            // Review L2: a tile stuck neither loaded nor missing must not freeze the display while the
            // index moves on. Show the frame anyway after a short wait (its missing tiles fill in).
            DispatchQueue.main.asyncAfter(deadline: .now() + RadarPolicy.incompleteTimeout + 0.05) { [weak self] in
                guard let self, self.waitTarget?.token == token0 else { return }
                self.showTarget(animated: true)
            }
            return
        }
        waitTarget = nil
        let token = Self.token(g, target)
        let onScreen = !states[0].drawable().isEmpty
        // Review M1 (build 47): frames are expanded off the main thread. On a miss the current frame
        // stays on screen and the switch happens once the background expansion lands.
        guard let images = takeExpanded(token) ?? (onScreen ? nil : expandNow(g.tiles[target])) else {
            expand(g, target) { [weak self] in
                guard let self, let g2 = self.active, g2 === g, self.shownIndex(g2) == target, self.shownFrame != target else { return }
                self.showTarget(animated: animated)
            }
            return
        }
        fade.show(target, at: CACurrentMediaTime(), animated: animated)
        shownFrame = target
        if animated, onScreen, Self.crossfadeEnabled, let map, bounds.width > 1 {
            startFade(g, target, token: token, images: images, visible: map.visibleMapRect)
        } else {
            removeCopies()
            commit(g, target, token: token, images: images)
            fade.finish()
        }
        expandAhead()
    }

    // MARK: Two-way crossfade over a renderer that always draws (build 48, review H1)

    /// MapKit's renderer always draws a real frame: it is never hidden, so removing a copy can never
    /// show an empty map. A switch runs in two phases, GPU only:
    /// 1. The new frame, as a Core Animation copy, fades in over the old frame (still drawn by MapKit).
    /// 2. MapKit redraws the new frame under the copy. Once it has actually drawn, the new-frame copy
    ///    is swapped (same transaction) for a copy of the old frame, which fades out over the new one.
    /// Both copies share the CGImages MapKit draws (no extra image memory).
    private var fadeLayers: [CALayer] = []
    private var waitTarget: (token: AnyHashable, since: CFTimeInterval)?
    /// The frame being faded in, until MapKit has it (`commit`); tiles arriving for it join its copy.
    private var incoming: (token: AnyHashable, layer: CALayer, images: [TileKey: CGImage])?
    private var fadeSerial = 0

    private func copyLayer(_ tiles: [(TileKey, CGImage)], visible v: MKMapRect) -> CALayer {
        let group = CALayer()
        group.frame = bounds
        group.actions = Self.noActions
        group.allowsGroupOpacity = false
        // Review L6: the copy is placed from this view's size, which must match the map's.
        assert(map.map { abs($0.bounds.width - bounds.width) < 1 && abs($0.bounds.height - bounds.height) < 1 } ?? true)
        for (key, image) in tiles { addTileLayer(key, image, to: group, visible: v) }
        return group
    }

    private static let noActions: [String: any CAAction] = ["opacity": NSNull(), "sublayers": NSNull(), "bounds": NSNull(), "position": NSNull(), "contents": NSNull()]

    private func addTileLayer(_ key: TileKey, _ image: CGImage, to group: CALayer, visible v: MKMapRect) {
        let scale = Double(bounds.width) / v.size.width
        let r = TileMath.rect(key)
        let x = (r.x - v.origin.x) * scale, yTop = (r.y - v.origin.y) * scale, size = r.width * scale
        let frame = CGRect(x: x, y: Double(bounds.height) - yTop - size, width: size, height: size)
        guard frame.intersects(bounds) else { return }
        let tile = CALayer()
        tile.actions = Self.noActions
        tile.contents = image
        tile.contentsGravity = .resize
        tile.magnificationFilter = .linear
        tile.minificationFilter = .linear
        tile.frame = frame
        tile.opacity = opacity
        tile.name = "\(key.z)/\(key.x)/\(key.y)"
        group.addSublayer(tile)
    }

    private func ordered(_ images: [TileKey: CGImage]) -> [(TileKey, CGImage)] {
        RadarPolicy.drawOrder(Array(images.keys), currentZoom: zoom).map { ($0, images[$0]!) }
    }

    private func fadeAnimation(from: Double, to: Double, duration: Double) -> CABasicAnimation {
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = from
        anim.toValue = to
        anim.duration = duration
        anim.fillMode = .both
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        anim.isRemovedOnCompletion = false
        return anim
    }

    private func startFade(_ g: Generation, _ target: Int, token: AnyHashable, images: [TileKey: CGImage], visible v: MKMapRect) {
        guard let host = layer else { return }
        // A switch mid-fade: drop the copies; MapKit still shows a whole frame underneath.
        removeCopies()
        fadeSerial += 1
        let serial = fadeSerial
        let inc = copyLayer(ordered(images), visible: v)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        inc.opacity = 0
        host.addSublayer(inc)
        inc.add(fadeAnimation(from: 0, to: 1, duration: RadarCrossfade.fadeIn), forKey: "fade")
        CATransaction.commit()
        fadeLayers = [inc]
        incoming = (token, inc, images)
        DispatchQueue.main.asyncAfter(deadline: .now() + RadarCrossfade.fadeIn) { [weak self] in
            guard let self, self.fadeSerial == serial, let pending = self.incoming, pending.token == token,
                  let g2 = self.active, g2 === g, g2.tiles.indices.contains(target) else { return }
            let old = self.states[0].drawable()
            let drawsBefore = self.states[0].drawCount
            self.commit(g2, target, token: token, images: pending.images)
            self.awaitDraw(since: drawsBefore) { [weak self] in
                guard let self, self.fadeSerial == serial, let host = self.layer, let map = self.map else { return }
                // Phase 2, same transaction: the new frame is MapKit's now; the old one fades out on top.
                let out = self.copyLayer(old, visible: map.visibleMapRect)
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                host.addSublayer(out)
                out.add(self.fadeAnimation(from: 1, to: 0, duration: RadarCrossfade.fadeOut), forKey: "fade")
                self.fadeLayers.forEach { $0.removeFromSuperlayer() }
                CATransaction.commit()
                self.fadeLayers = [out]
                DispatchQueue.main.asyncAfter(deadline: .now() + RadarCrossfade.fadeOut + 0.02) { [weak self] in
                    guard let self, self.fadeSerial == serial else { return }
                    self.removeCopies()
                    self.fade.finish()
                }
            }
        }
    }

    /// Hands a frame to MapKit's renderer.
    private func commit(_ g: Generation, _ i: Int, token: AnyHashable, images: [TileKey: CGImage]) {
        if incoming?.token == token { incoming = nil }
        states[0].set(g.tiles[i], zoom: zoom, token: token, prebuilt: images)
        renderers[0]?.setNeedsDisplay()
    }

    /// Calls `done` once MapKit has drawn after `since` and gone quiet for two display frames (its
    /// redraw is asynchronous and piecewise), or after 0.5 s (nothing visible to draw).
    private func awaitDraw(since: Int, started: CFTimeInterval = CACurrentMediaTime(), _ done: @escaping () -> Void) {
        let now = CACurrentMediaTime()
        let drew = states[0].drawCount > since && now - states[0].lastDraw > 0.033
        if drew || now - started > 0.5 { done(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 120) { [weak self] in
            self?.awaitDraw(since: since, started: started, done)
        }
    }

    private func removeCopies() {
        fadeSerial += 1
        guard !fadeLayers.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fadeLayers.forEach { $0.removeFromSuperlayer() }
        CATransaction.commit()
        fadeLayers = []
    }

    /// The copies are placed for the old size: drop them (MapKit's frame is underneath).
    func sizeWillChange() { cancelFade() }

    /// Drops the copies at once (pan, resize, close). MapKit is always drawing a whole frame under
    /// them, so nothing goes blank; a frame still fading in is handed to MapKit straight away.
    private func cancelFade() {
        let pending = incoming
        removeCopies()
        incoming = nil
        if let pending, let g = active, let f = shownFrame, Self.token(g, f) == pending.token {
            commit(g, f, token: pending.token, images: pending.images)
        }
        fade.finish()
    }

    // MARK: Expanding frames off the main thread (review M1/M3)

    private static let expandQueue = DispatchQueue(label: "skyline.radar.expand", qos: .userInitiated)
    private var ahead: [AnyHashable: [TileKey: CGImage]] = [:]
    private var aheadOrder: [AnyHashable] = []
    private var aheadInFlight: [AnyHashable: [() -> Void]] = [:]

    private func takeExpanded(_ token: AnyHashable) -> [TileKey: CGImage]? {
        guard let images = ahead.removeValue(forKey: token) else { return nil }
        aheadOrder.removeAll { $0 == token }
        return images
    }

    /// First frame only (nothing on screen to hold): expanded at once.
    private func expandNow(_ tiles: [TileKey: RadarTile]) -> [TileKey: CGImage] {
        tiles.compactMapValues { $0.image() }
    }

    /// Expands the next two frames in the background, so a switch only swaps images.
    private func expandAhead() {
        guard let g = active, g.frames.count > 1, let shown = shownFrame else { return }
        for step in 1...min(2, g.frames.count - 1) {
            let i = (shown + step) % g.frames.count
            if g.isComplete(i, desired: desired) { expand(g, i, then: nil) }
        }
    }

    private func expand(_ g: Generation, _ i: Int, then done: (() -> Void)?) {
        let token = Self.token(g, i)
        if ahead[token] != nil { done.map { DispatchQueue.main.async(execute: $0) }; return }
        if aheadInFlight[token] != nil { if let done { aheadInFlight[token]!.append(done) }; return }
        aheadInFlight[token] = done.map { [$0] } ?? []
        let tiles = g.tiles[i]
        Self.expandQueue.async { [weak self] in
            var images: [TileKey: CGImage] = [:]
            autoreleasepool { for (key, tile) in tiles { images[key] = tile.image() } }
            DispatchQueue.main.async {
                guard let self else { return }
                let callbacks = self.aheadInFlight.removeValue(forKey: token) ?? []
                guard self.active === g else { return }
                // Tiles that arrived while expanding are added on the next show (RadarDrawState.set).
                self.ahead[token] = images
                self.aheadOrder.removeAll { $0 == token }
                self.aheadOrder.append(token)
                // Two prepared frames at most (each ~12-25 MB expanded).
                while self.aheadOrder.count > 2 { self.ahead[self.aheadOrder.removeFirst()] = nil }
                callbacks.forEach { $0() }
            }
        }
    }

    private func dropAhead() { ahead = [:]; aheadOrder = [] }

    private func applyAlphas() {
        renderers[0]?.alpha = CGFloat(opacity)
        for group in fadeLayers { group.sublayers?.forEach { $0.opacity = opacity } }
    }

    /// The frame on screen gained or lost tiles (loading, pruning, zoom change): redraw it in place.
    /// A tile arriving for the frame still fading in is added to its copy as one layer (review L2).
    private func refreshShown(_ key: TileKey? = nil) {
        guard let g = active, let f = shownFrame, g.tiles.indices.contains(f) else { return }
        let token = Self.token(g, f)
        if var pending = incoming, pending.token == token {
            if let key, let tile = g.tiles[f][key], pending.images[key] == nil, let image = tile.image(), let map {
                pending.images[key] = image
                incoming = pending
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                addTileLayer(key, image, to: pending.layer, visible: map.visibleMapRect)
                CATransaction.commit()
            } else if key == nil {
                cancelFade() // pruning or a zoom change: hand the frame to MapKit as it is
            }
            return
        }
        states[0].set(g.tiles[f], zoom: zoom, token: token)
        if let key {
            let r = TileMath.rect(key)
            renderers[0]?.setNeedsDisplay(MKMapRect(x: r.x, y: r.y, width: r.width, height: r.height))
        } else {
            renderers[0]?.setNeedsDisplay()
        }
    }

    // MARK: Tiles

    var horizontalInset: CGFloat = 0

    private func visibleRect(_ v: MKMapRect) -> MapRectValue {
        let frac = bounds.width > 1 ? min(max(Double(horizontalInset / bounds.width), 0), 0.45) : 0
        let dx = v.size.width * frac
        return MapRectValue(x: v.origin.x + dx, y: v.origin.y, width: v.size.width - 2 * dx, height: v.size.height)
    }

    private func ringTiles() -> [TileKey] {
        guard let map else { return [] }
        return TileMath.tiles(covering: visibleRect(map.visibleMapRect), z: zoom, margin: 1)
    }

    /// Frames a generation needs, in load order (shown, next 3, rest). A fresh-scan generation loading
    /// while the old one plays holds only the shown frame and the next 3 until it is swapped in.
    private func neededFrames(_ g: Generation) -> [Int] {
        let holds = follows && playback?.holdsLoop == true
        let limit = g === pending && active?.frames.isEmpty == false
        return RadarPolicy.loadOrder(count: g.frames.count, shown: shownIndex(g), holdsLoop: holds, limitToAhead: limit)
    }

    /// Mid-gesture: MapKit already moves the radar with the map. Edge loading is coalesced to at most
    /// one pass per 150 ms, and nothing is pruned until the gesture settles.
    func gestureMoved() {
        // The fading copy is a plain layer that doesn't move with the map: drop it at once.
        cancelFade()
        guard !gestureWorkScheduled else { return }
        gestureWorkScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            self.gestureWorkScheduled = false
            self.updateTiles(allowZoomChange: false, prune: false)
        }
    }

    func updateTiles(allowZoomChange: Bool, prune doPrune: Bool = true) {
        guard let map, bounds.width > 1, bounds.height > 1 else { return }
        let v = map.visibleMapRect
        guard v.size.width > 0 else { return }
        let visible = visibleRect(v)
        let z = RadarPolicy.zoom(visible: visible, viewWidth: Double(max(bounds.width - 2 * horizontalInset, 1)), maxZ: maxZ,
                                 perFrameBudget: Self.tileBudget)
        let zoomChanged = (allowZoomChange || zoom == 0) && z != zoom
        if allowZoomChange || zoom == 0 { zoom = z }
        desired = TileMath.tiles(covering: visible, z: zoom, margin: 0)
        let ring = TileMath.tiles(covering: visible, z: zoom, margin: 1)
        keep = Set(ring)
        var shownChanged = zoomChanged
        for g in [active, pending].compactMap({ $0 }) {
            let needed = neededFrames(g)
            // Every needed frame keeps the one-tile edge ring (build 42).
            request(ring, in: g, frames: needed)
            if doPrune {
                let neededSet = Set(needed)
                for i in g.frames.indices where prune(g, i, needed: neededSet.contains(i)) && g === active && i == shownFrame {
                    shownChanged = true
                }
            }
        }
        if shownChanged { refreshShown() }
        promotePendingIfReady()
        if shownFrame != active.map(shownIndex) { showTarget(animated: false) }
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
                        self.promotePendingIfReady()
                        // The playback's frame may have become complete: show it now.
                        if g === self.active, i == self.shownIndex(g), self.shownFrame != i { self.showTarget(animated: false) }
                        self.scheduleProgressReport()
                    }
                }
            }
        }
    }

    private func addTile(_ image: RadarTile, key: TileKey, frame i: Int, in g: Generation) {
        guard g.tiles[i][key] == nil, key.z == zoom else { return }
        g.tiles[i][key] = image
        Self.liveTiles += 1
        Self.addedTiles += 1
        if g === active, i == shownFrame { refreshShown(key) }
    }

    /// Drops tiles outside the ring, frames no longer needed, and other-zoom placeholders once the
    /// current zoom is complete. Only runs once a gesture settles. Returns whether anything went.
    @discardableResult
    private func prune(_ g: Generation, _ i: Int, needed: Bool) -> Bool {
        // Never empty the frame on screen (or fading in): it stays until its replacement shows.
        let onScreen = g === active && i == shownFrame
        let complete = g.isComplete(i, desired: desired)
        var removed = 0
        for key in Array(g.tiles[i].keys) {
            let stale = (!needed && !onScreen) || (key.z == zoom ? !keep.contains(key) : complete)
            if stale { g.tiles[i][key] = nil; removed += 1 }
        }
        Self.liveTiles -= removed
        g.missing[i] = g.missing[i].filter { $0.z == zoom }
        return removed > 0
    }

    private func promotePendingIfReady() {
        guard let p = pending, p.isComplete(shownIndex(p), desired: desired) else { return }
        // Swap: the old set is released here, then the new one fills the rest of its loop.
        active = p
        pending = nil
        dropAhead()
        shownFrame = nil
        showTarget(animated: false)
        updateTilesSoon()
    }

    private var updateScheduled = false
    private func updateTilesSoon() {
        guard !updateScheduled else { return }
        updateScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.updateScheduled = false
            self?.updateTiles(allowZoomChange: false)
        }
    }

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

    // MARK: Measurement (pan test, memory log)

    /// On-screen tiles of the frame being shown that are neither loaded nor known-missing.
    func visibleHolesInShownFrame() -> Int {
        guard let g = active, let f = shownFrame else { return desired.count }
        return desired.filter { g.tiles[f][$0] == nil && !g.missing[f].contains($0) }.count
    }

    /// Ring tiles not yet loaded, over every needed frame (edge readiness for a pan).
    func missingRingTiles() -> Int {
        guard let g = active else { return 0 }
        return neededFrames(g).reduce(0) { n, i in n + keep.filter { g.tiles[i][$0] == nil && !g.missing[i].contains($0) }.count }
    }

    var heldTileCount: Int { [active, pending].compactMap { $0 }.reduce(0) { $0 + $1.tiles.reduce(0) { $0 + $1.count } } }
}

/// DEBUG tripwire for the crash rule above (L1): set while SwiftUI runs `makeNSView`/`updateNSView`, and
/// checked by `RadarPlayback`'s observed setters, so a future synchronous state write from inside an
/// update pass fails loudly in debug builds instead of looping in release.
@MainActor
enum SwiftUIUpdatePass {
    private(set) static var depth = 0
    static var isActive: Bool { depth > 0 }
    static func enter() { depth += 1 }
    static func leave() { depth -= 1 }
    static func assertOutside(_ what: @autoclosure () -> String) {
        #if DEBUG
        assert(!isActive, "Observed state (\(what())) written inside a SwiftUI view update")
        #endif
    }
}
