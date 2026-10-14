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

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            // Continuous during gestures: MapKit moves the radar itself; only the pin/alerts follow, and
            // edge loading is coalesced (no pruning, no zoom change).
            container?.regionChanged(settled: false)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
            if let container, overlay === container.radar.overlay { return container.radar.makeRenderer() }
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

/// The radar as a MapKit overlay (build 35): one world-sized overlay whose renderer paints the shown
/// frame's decoded tiles. MapKit draws it in the same render pass as the base map, so the radar can't
/// lag, slide or pop at the edges while panning or zooming (radar-pan-diagnosis cause 3).
final class RadarOverlay: NSObject, MKOverlay {
    let coordinate = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    let boundingMapRect = MKMapRect.world
    func canReplaceMapContent() -> Bool { false }
}

/// What the renderer draws, swapped atomically from the main thread and read on MapKit's draw threads.
final class RadarDrawState: @unchecked Sendable {
    private let lock = NSLock()
    private var tiles: [(TileKey, CGImage)] = []
    func set(_ new: [(TileKey, CGImage)]) { lock.lock(); tiles = new; lock.unlock() }
    func snapshot() -> [(TileKey, CGImage)] { lock.lock(); defer { lock.unlock() }; return tiles }
}

final class RadarOverlayRenderer: MKOverlayRenderer {
    let state: RadarDrawState

    init(overlay: RadarOverlay, state: RadarDrawState) {
        self.state = state
        super.init(overlay: overlay)
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        let tiles = state.snapshot()
        guard !tiles.isEmpty else { return }
        context.interpolationQuality = .medium
        // Coarser tiles first, so finer ones (current zoom) paint over leftover placeholders.
        for (key, image) in tiles.sorted(by: { $0.0.z < $1.0.z }) {
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

/// Radar tile manager: loads and holds each frame's decoded tiles and hands the shown frame to the
/// MapKit overlay renderer. Invisible and click-through; it only borrows the container's size.
final class RadarLayerView: NSView {
    nonisolated(unsafe) static var liveTiles = 0
    /// Tiles added since launch (measurement log: a steady loop should stop adding).
    nonisolated(unsafe) static var addedTiles = 0
    weak var map: MKMapView? {
        didSet { attachOverlay() }
    }

    /// Per-frame zoom budget (decoded tiles a single frame may cover). Playing no longer lowers the zoom
    /// (build 35: quality first), so this only matters for huge windows.
    static let tileBudget = max(40, UserDefaults.standard.object(forKey: "SkylineTileBudget") as? Int ?? 160)

    let overlay = RadarOverlay()
    let drawState = RadarDrawState()
    private(set) var renderer: RadarOverlayRenderer?

    /// One prefetched set of frames. A new set (fresh scans) is loaded in the background as `pending` and
    /// only swapped in once its shown frame is loaded, so the radar never blanks.
    private final class Generation {
        let frames: [RadarFrame]
        var tiles: [[TileKey: CGImage]]
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
    private var opacity: Float = Float(RadarOpacity.defaultValue)
    private var retryObserver: NSObjectProtocol?

    private weak var playback: RadarPlayback?
    private var follows = true
    private var reportsProgress = false
    private var progressScheduled = false
    private var gestureWorkScheduled = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Failed tiles are asked for again after a back-off, on wake and when the network returns (T15).
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

    private func attachOverlay() {
        guard let map, !map.overlays.contains(where: { $0 === overlay }) else { return }
        // Above roads and labels, like the old layer stack (normal source-over at the user's opacity).
        map.addOverlay(overlay, level: .aboveLabels)
    }

    /// The map delegate asks for the renderer.
    func makeRenderer() -> RadarOverlayRenderer {
        let r = RadarOverlayRenderer(overlay: overlay, state: drawState)
        r.alpha = CGFloat(opacity)
        renderer = r
        return r
    }

    /// Re-requests tiles marked missing whose failure verdict has expired (back-off over, wake, network
    /// back). Event-driven from a notification on the main queue: never inside layout.
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

    /// Playback started/stopped needing the whole loop: load it, or release every frame but the one shown.
    /// The zoom is kept (build 35: playing never drops resolution).
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
            publishShownFrame()
        }
        if r { scheduleProgressReport() }
    }

    func disconnect() {
        playback?.removeSink(self)
        playback = nil
    }

    private var lastIndex: Int { max(0, ((pending ?? active)?.frames.count ?? 1) - 1) }

    /// Called by RadarPlayback when its frame index changes (timer or scrubber) — never during layout.
    /// Every held frame is already decoded, so a frame change is one redraw.
    func playbackIndexChanged(_ newIndex: Int, animated: Bool) {
        guard follows, newIndex != index else { return }
        index = newIndex
        publishShownFrame()
        if let g = active { request(TileMath.tiles(covering: visibleRectNow(), z: zoom, margin: 1), in: g, frames: Array(ringFrames(g))) }
    }

    private func visibleRectNow() -> MapRectValue {
        guard let map else { return MapRectValue(x: 0, y: 0, width: 0, height: 0) }
        return visibleRect(map.visibleMapRect)
    }

    func setOpacity(_ value: Float) {
        guard value != opacity else { return }
        opacity = value
        renderer?.alpha = CGFloat(value)
    }

    // MARK: Frames

    func setFrames(_ frames: [RadarFrame], maxZ: Int) {
        let ids = frames.map(\.id)
        if ids == (pending ?? active)?.frames.map(\.id), maxZ == self.maxZ { return }
        self.maxZ = maxZ
        let generation = Generation(frames: frames)
        if active == nil || frames.isEmpty || active?.frames.isEmpty == true {
            pending = nil
            active = generation
        } else {
            pending = generation
        }
        index = follows ? min(playback?.index ?? lastIndex, max(0, frames.count - 1)) : lastIndex
        zoom = 0
        publishShownFrame()
        updateTiles(allowZoomChange: true)
    }

    /// Hands the shown frame's tiles (current zoom plus coarser/finer placeholders still held) to the
    /// renderer and redraws.
    private func publishShownFrame() {
        guard let g = active, !g.frames.isEmpty else {
            drawState.set([])
            renderer?.setNeedsDisplay()
            return
        }
        let shown = min(max(index, 0), g.frames.count - 1)
        drawState.set(g.tiles[shown].map { ($0.key, $0.value) })
        renderer?.setNeedsDisplay()
    }

    private func shownIndex(_ g: Generation) -> Int { min(max(index, 0), max(g.frames.count - 1, 0)) }

    // MARK: Tiles

    /// Points clipped off each side by the container's overscan; tiles there are never visible.
    var horizontalInset: CGFloat = 0

    /// The part of the map actually on screen (minus the clipped overscan), in map points.
    private func visibleRect(_ v: MKMapRect) -> MapRectValue {
        let frac = bounds.width > 1 ? min(max(Double(horizontalInset / bounds.width), 0), 0.45) : 0
        let dx = v.size.width * frac
        return MapRectValue(x: v.origin.x + dx, y: v.origin.y, width: v.size.width - 2 * dx, height: v.size.height)
    }

    /// Frames this view needs loaded: all of them while playback needs the loop (playing, scrubbing, or
    /// just paused), else only the one shown.
    private func neededFrames(_ g: Generation) -> [Int] {
        guard !g.frames.isEmpty else { return [] }
        let shown = shownIndex(g)
        guard follows, playback?.holdsLoop == true else { return [shown] }
        var order = [shown]
        for i in g.frames.indices.reversed() where i != shown { order.append(i) } // newest → oldest
        return order
    }

    /// Frames that keep the one-tile edge ring: the shown frame and the next three the loop will show
    /// (radar-pan-diagnosis fix 1, "shown + 2-3"), which keeps the playing loop under the ~350 MB ceiling.
    /// Every other held frame keeps its full on-screen set at full zoom; nothing is pruned mid-gesture.
    static let ringAhead = 3
    private func ringFrames(_ g: Generation) -> Set<Int> {
        guard !g.frames.isEmpty else { return [] }
        let shown = shownIndex(g)
        guard follows, playback?.holdsLoop == true else { return [shown] }
        return Set((0...Self.ringAhead).map { (shown + $0) % g.frames.count })
    }

    /// Mid-gesture: MapKit already moves the radar with the map, so nothing is repositioned. Loading the
    /// newly exposed edge is coalesced to at most one pass per 150 ms, and nothing is pruned until the
    /// gesture settles (diagnosis fixes 1 and 5).
    func gestureMoved() {
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
        // One frame's worth of budget: the zoom is the same paused or playing (build 35, quality first).
        let z = TileMath.zoom(fitting: visible, viewWidth: Double(max(bounds.width - 2 * horizontalInset, 1)), maxZ: maxZ,
                              frames: 1, tileBudget: Self.tileBudget)
        let zoomChanged = (allowZoomChange || zoom == 0) && z != zoom
        if allowZoomChange || zoom == 0 { zoom = z }
        desired = TileMath.tiles(covering: visible, z: zoom, margin: 0)
        // Every held frame keeps a one-tile ring, so a pan never exposes an empty edge on any frame.
        keep = Set(TileMath.tiles(covering: visible, z: zoom, margin: 1))
        let ring = TileMath.tiles(covering: visible, z: zoom, margin: 1)
        var shownChanged = false
        for g in [active, pending].compactMap({ $0 }) {
            let needed = neededFrames(g)
            let ringed = ringFrames(g)
            request(ring, in: g, frames: needed.filter { ringed.contains($0) })
            request(desired, in: g, frames: needed.filter { !ringed.contains($0) })
            if doPrune {
                for i in g.frames.indices where prune(g, i, needed: needed.contains(i), ring: ringed.contains(i)) && g === active && i == shownIndex(g) {
                    shownChanged = true
                }
            }
        }
        if shownChanged || zoomChanged { publishShownFrame() }
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
                        self.promotePendingIfReady()
                        self.scheduleProgressReport()
                    }
                }
            }
        }
    }

    private func addTile(_ image: CGImage, key: TileKey, frame i: Int, in g: Generation) {
        guard g.tiles[i][key] == nil, key.z == zoom else { return }
        g.tiles[i][key] = image
        Self.liveTiles += 1
        Self.addedTiles += 1
        if g === active, i == shownIndex(g) {
            drawState.set(g.tiles[i].map { ($0.key, $0.value) })
            let r = TileMath.rect(key)
            renderer?.setNeedsDisplay(MKMapRect(x: r.x, y: r.y, width: r.width, height: r.height))
        }
    }

    /// Drops tiles outside the ring, frames this view no longer needs, and other-zoom placeholders once
    /// the current zoom is complete. Only runs once a gesture settles. Returns whether anything went.
    @discardableResult
    private func prune(_ g: Generation, _ i: Int, needed: Bool, ring: Bool = true) -> Bool {
        let complete = g.isComplete(i, desired: desired)
        let onScreen = ring ? keep : Set(desired)
        var removed = 0
        for key in Array(g.tiles[i].keys) {
            let stale = !needed || (key.z == zoom ? !onScreen.contains(key) : complete)
            if stale { g.tiles[i][key] = nil; removed += 1 }
        }
        Self.liveTiles -= removed
        g.missing[i] = g.missing[i].filter { $0.z == zoom }
        return removed > 0
    }

    private func promotePendingIfReady() {
        guard let p = pending, p.isComplete(shownIndex(p), desired: desired) else { return }
        active = p
        pending = nil
        publishShownFrame()
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
