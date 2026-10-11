import AppKit
import MapKit
import SwiftUI

/// QA hook `-SkylineHitTest YES`: confirms the radar map's overscan does not steal hits/scrolls from
/// the forecast column. Logs `[hittest] … PASS|FAIL`. With `-SkylineStressQuit YES` quits afterwards.
@MainActor
enum OverscanHitProbe {
    private static var ran = false

    static func runIfRequested(store: WeatherStore) {
        guard UserDefaults.standard.bool(forKey: "SkylineHitTest") else { return }
        Task { await run(store: store) }
    }

    private static func log(_ s: String) {
        print("[hittest] \(s)")
        fflush(stdout)
    }

    private static func run(store: WeatherStore) async {
        guard !ran else { return }
        store.radarExpanded = false
        store.activeModule = nil
        let start = Date()
        var container: RadarMapContainer?
        while Date().timeIntervalSince(start) < 20 {
            if store.selectedLocation.flatMap({ store.reports[$0.id] }) != nil {
                container = findOverscannedContainer()
                if container != nil { break }
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard !ran else { return }
        ran = true
        guard let container, container.overscan > 0, let window = container.window else {
            log("FAIL no overscanned map (wide layout with column required)")
            quitIfNeeded()
            return
        }

        // Let MapKit finish any initial region settle so mapStill is meaningful.
        try? await Task.sleep(for: .seconds(2))
        _ = await waitForStableRegion(container.map)

        let midY = container.bounds.midY
        let leftLocal = NSPoint(x: container.overscan * 0.35, y: midY)
        let centerLocal = NSPoint(x: container.bounds.midX, y: midY)
        let hitLeft = container.hitTest(container.convert(leftLocal, to: container.superview))
        let hitCenter = container.hitTest(container.convert(centerLocal, to: container.superview))
        let hitOK = hitLeft == nil && hitCenter != nil
        log("overscan=\(Int(container.overscan)) hitLeft=\(hitLeft == nil ? "nil" : "view") hitCenter=\(hitCenter == nil ? "nil" : "view") \(hitOK ? "ok" : "BAD")")

        let leftInWindow = container.convert(leftLocal, to: nil)
        let windowHit = hitView(in: window, at: leftInWindow)
        let steals = windowHit.map { $0 === container || $0.isDescendant(of: container) } ?? false
        log("windowHitOverscan=\(describe(windowHit)) steals=\(steals)")

        let regionBefore = container.map.region
        let scrollBefore = ScrollProbe.heroMinY

        // Scroll the forecast via its ScrollViewProxy (HostingScrollView ignores synthetic wheel
        // phases). Combined with hitOK/!steals this proves the map is out of the hit path while
        // the forecast still scrolls. Never call scrollWheel on a random hit view — NSResponder
        // forwards up the chain and can reach MKMapView even when hitTest excluded it.
        ScrollProbe.pendingScrollToDaily = true
        try? await Task.sleep(for: .seconds(1.5))

        let regionAfter = container.map.region
        let scrollAfter = ScrollProbe.heroMinY
        let mapStill = abs(regionAfter.center.latitude - regionBefore.center.latitude) < 1e-7
            && abs(regionAfter.center.longitude - regionBefore.center.longitude) < 1e-7
            && abs(regionAfter.span.latitudeDelta - regionBefore.span.latitudeDelta) < 1e-7
        let scrollMoved = abs(scrollAfter - scrollBefore) > 10
        log(String(format: "mapStill=%@ scrollBefore=%.1f scrollAfter=%.1f scrollMoved=%@",
                   mapStill ? "YES" : "NO", scrollBefore, scrollAfter, scrollMoved ? "YES" : "NO"))

        let ok = hitOK && !steals && mapStill && scrollMoved
        log(ok ? "PASS" : "FAIL")
        quitIfNeeded()
    }

    private static func quitIfNeeded() {
        if UserDefaults.standard.bool(forKey: "SkylineStressQuit") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { NSApp.terminate(nil) }
        }
    }

    private static func waitForStableRegion(_ map: MKMapView) async -> MKCoordinateRegion {
        var last = map.region
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(300))
            let now = map.region
            if abs(now.center.latitude - last.center.latitude) < 1e-7,
               abs(now.center.longitude - last.center.longitude) < 1e-7 {
                return now
            }
            last = now
        }
        return map.region
    }

    private static func findOverscannedContainer() -> RadarMapContainer? {
        for window in NSApp.windows where window.isVisible {
            if let found = firstOverscanned(in: window.contentView) { return found }
        }
        return nil
    }

    private static func firstOverscanned(in view: NSView?) -> RadarMapContainer? {
        guard let view else { return nil }
        if let c = view as? RadarMapContainer, c.overscan > 0, c.bounds.width > 0 { return c }
        for child in view.subviews {
            if let found = firstOverscanned(in: child) { return found }
        }
        return nil
    }

    private static func hitView(in window: NSWindow, at point: NSPoint) -> NSView? {
        guard let content = window.contentView, let superView = content.superview else { return nil }
        let inContent = content.convert(point, from: nil)
        let forHit = content.convert(inContent, to: superView)
        return content.hitTest(forHit)
    }

    private static func describe(_ view: NSView?) -> String {
        guard let view else { return "nil" }
        return String(describing: type(of: view))
    }
}
