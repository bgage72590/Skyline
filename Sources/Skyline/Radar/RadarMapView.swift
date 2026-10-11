import AppKit
import MapKit
import SwiftUI
import SkylineCore

/// One radar frame as a MapKit tile overlay.
final class RadarTileOverlay: MKTileOverlay {
    let frame: RadarFrame
    let maxNativeZoom: Int

    init(frame: RadarFrame, maxNativeZoom: Int) {
        self.frame = frame
        self.maxNativeZoom = maxNativeZoom
        super.init(urlTemplate: nil)
        canReplaceMapContent = false
        tileSize = CGSize(width: 256, height: 256)
        minimumZ = 1
        maximumZ = 18
    }

    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        frame.url(z: path.z, x: path.x, y: path.y) ?? URL(string: "about:blank")!
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        // MapKit calls `result` from any thread; hand it through as an unchecked-Sendable box.
        let box = ResultBox(result)
        RadarTileLoader.shared.load(frame: frame, z: path.z, x: path.x, y: path.y,
                                    maxNativeZoom: maxNativeZoom) { data, error in box.call(data, error) }
    }

    private final class ResultBox: @unchecked Sendable {
        let fn: (Data?, Error?) -> Void
        init(_ fn: @escaping (Data?, Error?) -> Void) { self.fn = fn }
        func call(_ d: Data?, _ e: Error?) { fn(d, e) }
    }
}

/// MKMapView with every radar frame added as an overlay. Animation only flips renderer alpha
/// (no re-download, no re-layout): the current frame is fully visible and the previous frame
/// lingers faintly, which reads as a smooth cross-fade without extra timer ticks.
struct RadarMapView: NSViewRepresentable {
    var center: Coordinate
    var frames: [RadarFrame]
    var index: Int
    var maxNativeZoom: Int
    var interactive: Bool
    var spanDegrees: Double = 5
    var opacity: Double = 0.75

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        map.isZoomEnabled = interactive
        map.isScrollEnabled = interactive
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        map.showsCompass = false
        map.showsZoomControls = interactive
        map.showsScale = interactive
        map.pointOfInterestFilter = .excludingAll
        context.coordinator.recenter(map, on: center, span: spanDegrees, animated: false)
        context.coordinator.sync(map, frames: frames, maxNativeZoom: maxNativeZoom)
        context.coordinator.show(index: index, opacity: opacity)
        return map
    }

    func updateNSView(_ map: MKMapView, context: Context) {
        let c = context.coordinator
        if c.center != center { c.recenter(map, on: center, span: spanDegrees, animated: true) }
        c.sync(map, frames: frames, maxNativeZoom: maxNativeZoom)
        c.show(index: index, opacity: opacity)
    }

    static func dismantleNSView(_ map: MKMapView, coordinator: Coordinator) {
        map.removeOverlays(map.overlays)
        map.delegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate {
        var center: Coordinate?
        private var overlays: [RadarTileOverlay] = []
        private var renderers: [ObjectIdentifier: MKTileOverlayRenderer] = [:]
        private var frameIDs: [String] = []
        private var shownIndex = -1
        private var shownOpacity = -1.0
        private let pin = MKPointAnnotation()

        func recenter(_ map: MKMapView, on c: Coordinate, span: Double, animated: Bool) {
            center = c
            let coordinate = CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude)
            map.setRegion(MKCoordinateRegion(center: coordinate,
                                             span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span)),
                          animated: animated)
            pin.coordinate = coordinate
            if !map.annotations.contains(where: { $0 === pin }) { map.addAnnotation(pin) }
        }

        func sync(_ map: MKMapView, frames: [RadarFrame], maxNativeZoom: Int) {
            let ids = frames.map(\.id)
            guard ids != frameIDs else { return }
            map.removeOverlays(overlays)
            renderers.removeAll()
            overlays = frames.map { RadarTileOverlay(frame: $0, maxNativeZoom: maxNativeZoom) }
            frameIDs = ids
            shownIndex = -1
            map.addOverlays(overlays, level: .aboveRoads)
        }

        func show(index: Int, opacity: Double) {
            guard index != shownIndex || opacity != shownOpacity else { return }
            shownIndex = index
            shownOpacity = opacity
            for (i, overlay) in overlays.enumerated() {
                guard let r = renderers[ObjectIdentifier(overlay)] else { continue }
                let a = alpha(for: i)
                if abs(r.alpha - a) > 0.001 {
                    r.alpha = a
                    r.setNeedsDisplay()
                }
            }
        }

        private func alpha(for i: Int) -> CGFloat {
            guard shownIndex >= 0 else { return i == overlays.count - 1 ? CGFloat(shownOpacity) : 0 }
            if i == shownIndex { return CGFloat(shownOpacity) }
            if i == shownIndex - 1 { return CGFloat(shownOpacity * 0.25) }
            return 0
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let tile = overlay as? RadarTileOverlay else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKTileOverlayRenderer(tileOverlay: tile)
            renderers[ObjectIdentifier(tile)] = renderer
            if let i = overlays.firstIndex(where: { $0 === tile }) { renderer.alpha = alpha(for: i) }
            return renderer
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard annotation === pin else { return nil }
            let view = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "pin")
            view.markerTintColor = .systemBlue
            view.glyphImage = NSImage(systemSymbolName: "location.fill", accessibilityDescription: nil)
            return view
        }
    }
}
