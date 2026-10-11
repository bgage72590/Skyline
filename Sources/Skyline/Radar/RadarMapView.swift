import AppKit
import MapKit
import QuartzCore
import SwiftUI
import SkylineCore

/// MapKit base map + a Core Animation radar layer stack on top.
///
/// Why not `MKTileOverlay`: swapping or re-alpha-ing tile overlays makes MapKit re-request and redraw
/// tiles, which is what caused blank tiles and flashing. Here every frame owns one CALayer whose tile
/// sublayers are filled from `RadarImageCache` *before* playback starts. Changing frames only animates
/// layer opacity (a GPU cross-fade), and pan/zoom just repositions the existing tile layers.
struct RadarMapView: NSViewRepresentable {
    var center: Coordinate
    var frames: [RadarFrame]
    var index: Int
    var maxNativeZoom: Int
    var interactive: Bool
    var spanDegrees: Double
    var opacity: Double
    var pinText: String?
    /// Whether frame changes cross-fade (false while the user scrubs).
    var crossfade: Bool = true
    var onProgress: ((Double) -> Void)?

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
        c.setPin(text: pinText)
        container.radar.onProgress = onProgress
        container.radar.setFrames(frames, maxZ: maxNativeZoom)
        container.radar.show(index: index, opacity: Float(opacity), animated: crossfade)
    }

    static func dismantleNSView(_ container: RadarMapContainer, coordinator: Coordinator) {
        container.map.delegate = nil
        container.radar.onProgress = nil
    }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate {
        weak var container: RadarMapContainer?
        var center: Coordinate?
        private var pinText: String?

        func recenter(on c: Coordinate, span: Double) {
            guard let map = container?.map else { return }
            center = c
            let coordinate = CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude)
            map.setRegion(MKCoordinateRegion(center: coordinate,
                                             span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span * 1.3)),
                          animated: false)
            container?.pinCoordinate = coordinate
            container?.radar.updateTiles(allowZoomChange: true)
            container?.layoutPin()
        }

        func setPin(text: String?) {
            guard text != pinText else { return }
            pinText = text
            container?.setPinText(text)
        }

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            // Continuous during gestures: reposition only, keep the zoom level (no tile churn).
            container?.radar.updateTiles(allowZoomChange: false)
            container?.layoutPin()
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            container?.radar.updateTiles(allowZoomChange: true)
            container?.layoutPin()
        }
    }
}

/// Hosts the map and the radar layer view at the same frame.
final class RadarMapContainer: NSView {
    let map = MKMapView()
    let radar = RadarLayerView()
    /// Location pin drawn above the radar (MapKit annotations would sit underneath it).
    private let pin = NSHostingView(rootView: LocationPin(text: nil))
    var pinCoordinate: CLLocationCoordinate2D?

    init(interactive: Bool) {
        super.init(frame: .zero)
        map.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
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
        map.pointOfInterestFilter = .excludingAll
        addSubview(map)
        addSubview(radar)
        addSubview(pin)
        radar.map = map
    }

    func setPinText(_ text: String?) {
        pin.rootView = LocationPin(text: text)
        layoutPin()
    }

    func layoutPin() {
        guard let pinCoordinate else { pin.isHidden = true; return }
        let point = map.convert(pinCoordinate, toPointTo: self)
        let size = pin.fittingSize
        pin.isHidden = !bounds.insetBy(dx: -size.width, dy: -size.height).contains(point)
        // Bubble's bottom tip sits on the coordinate (view is not flipped: y grows upward).
        pin.frame = CGRect(x: point.x - size.width / 2, y: point.y, width: size.width, height: size.height)
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
}

/// Temperature bubble marking the forecast location, like Apple Weather's map pin.
struct LocationPin: View {
    let text: String?
    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let text {
                    Text(text).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                } else {
                    Image(systemName: "location.fill").font(.system(size: 11, weight: .bold))
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .frame(minWidth: 32, minHeight: 26)
            .background(Capsule().fill(Color(red: 0.13, green: 0.42, blue: 0.95)))
            .overlay(Capsule().stroke(.white, lineWidth: 2))
            Circle().fill(.white).frame(width: 7, height: 7).padding(.top, 2)
                .shadow(color: .black.opacity(0.4), radius: 1)
        }
        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
        .allowsHitTesting(false)
    }
}

/// Transparent, click-through view holding one CALayer per radar frame.
final class RadarLayerView: NSView {
    weak var map: MKMapView?
    var onProgress: ((Double) -> Void)?

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
            desired.allSatisfy { tiles[i][$0] != nil || missing[i].contains($0) }
        }
    }

    private var active: Generation?
    private var pending: Generation?
    private var maxZ = 7
    private var zoom = 0
    private var desired: [TileKey] = []
    private var keep: Set<TileKey> = []
    private var index = 0
    private var opacity: Float = 0.8

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

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
        zoom = 0
        updateTiles(allowZoomChange: true)
    }

    func show(index newIndex: Int, opacity newOpacity: Float, animated: Bool) {
        guard newIndex != index || newOpacity != opacity || needsInitialShow else { return }
        let changedFrame = newIndex != index
        index = newIndex
        opacity = newOpacity
        needsInitialShow = false
        applyVisibility(animated: animated && changedFrame)
    }

    private var needsInitialShow = true

    private func applyVisibility(animated: Bool) {
        guard let g = active else { return }
        let shown = min(index, g.frames.count - 1)
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(0.35)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        for (i, frameLayer) in g.frameLayers.enumerated() {
            frameLayer.opacity = i == shown ? opacity : 0
        }
        CATransaction.commit()
    }

    // MARK: Tiles

    /// Recomputes the visible tile set, lays out existing tile layers and requests missing ones.
    func updateTiles(allowZoomChange: Bool) {
        guard let map, bounds.width > 1, bounds.height > 1 else { return }
        let v = map.visibleMapRect
        guard v.size.width > 0 else { return }
        let visible = MapRectValue(x: v.origin.x, y: v.origin.y, width: v.size.width, height: v.size.height)
        let z = TileMath.zoom(visibleWidth: v.size.width, viewWidth: Double(bounds.width), maxZ: maxZ)
        if allowZoomChange || zoom == 0 { zoom = z }
        desired = TileMath.tiles(covering: visible, z: zoom, margin: 0)
        keep = Set(TileMath.tiles(covering: visible, z: zoom, margin: 2))
        // Prefetch one tile ring beyond the edges so small pans never show gaps.
        let wanted = TileMath.tiles(covering: visible, z: zoom, margin: 1)
        layoutTiles(v)
        for g in [active, pending].compactMap({ $0 }) {
            request(wanted, in: g)
            for i in g.frames.indices { prune(g, i) }
        }
        promotePendingIfReady()
        reportProgress()
    }

    private func request(_ keys: [TileKey], in g: Generation) {
        // Current frame first, then newest → oldest, so the visible frame fills in first.
        let order = [min(index, g.frames.count - 1)] + g.frames.indices.reversed()
        var seen = Set<Int>()
        for i in order where i >= 0 && seen.insert(i).inserted {
            let frame = g.frames[i]
            for key in keys where g.tiles[i][key] == nil && !g.missing[i].contains(key) && !g.requested[i].contains(key) {
                guard let url = frame.url(z: key.z, x: key.x, y: key.y) else { continue }
                if let image = RadarImageCache.shared.image(for: url) {
                    addTile(image, key: key, frame: i, in: g)
                } else if RadarImageCache.shared.recentlyFailed(url) {
                    g.missing[i].insert(key)
                } else {
                    g.requested[i].insert(key)
                    RadarImageCache.shared.load(url) { [weak self, weak g] image in
                        guard let self, let g else { return }
                        g.requested[i].remove(key)
                        if let image { self.addTile(image, key: key, frame: i, in: g) } else { g.missing[i].insert(key) }
                        self.prune(g, i)
                        self.promotePendingIfReady()
                        self.reportProgress()
                    }
                }
            }
        }
    }

    private func addTile(_ image: CGImage, key: TileKey, frame i: Int, in g: Generation) {
        guard g.tiles[i][key] == nil, let map else { return }
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

    /// Drops tiles that scrolled far away, and lower/higher-zoom placeholders once the current zoom is complete.
    private func prune(_ g: Generation, _ i: Int) {
        let complete = g.isComplete(i, desired: desired)
        var removed: [TileKey] = []
        for (key, tile) in g.tiles[i] {
            let stale = key.z == zoom ? !keep.contains(key) : complete
            if stale {
                tile.removeFromSuperlayer()
                removed.append(key)
            }
        }
        for key in removed { g.tiles[i][key] = nil }
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

    private func reportProgress() {
        guard let onProgress else { return }
        let g = pending ?? active
        guard let g, !g.frames.isEmpty, !desired.isEmpty else { return onProgress(0) }
        var resolved = 0
        for i in g.frames.indices {
            resolved += desired.reduce(0) { $0 + ((g.tiles[i][$1] != nil || g.missing[i].contains($1)) ? 1 : 0) }
        }
        onProgress(Double(resolved) / Double(g.frames.count * desired.count))
    }

    private func layoutTiles(_ v: MKMapRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for g in [active, pending].compactMap({ $0 }) {
            g.root.frame = bounds
            for (i, frameLayer) in g.frameLayers.enumerated() {
                frameLayer.frame = bounds
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
