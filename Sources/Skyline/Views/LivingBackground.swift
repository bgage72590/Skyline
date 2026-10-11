import SwiftUI
import SkylineCore

/// A quieter living background: the condition gradient, plus — for rain, drizzle, storms and snow —
/// a faint layer of falling streaks/flakes, dimmed so it never competes with text.
///
/// Power rules: animates only while the main window is visible, not while the user scrubs a chart or
/// the radar, never with Reduce Motion, capped at 30 fps, and it settles to a still frame after
/// `animateFor` seconds (re-armed when the location or conditions change), so an idle window
/// costs ~0 % CPU. Particle positions are computed from time, so pausing never jumps.
struct LivingBackground: View {
    let report: WeatherReport?
    @Environment(WeatherStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var armedAt = Date()

    static let animateFor: TimeInterval = 40

    var body: some View {
        let category = report?.current.condition.category ?? .partlyCloudy
        ZStack {
            SkyPalette.gradient(for: report)
            if let kind = Particles.Kind(category) {
                let canAnimate = store.isMainWindowVisible && !store.isScrubbing && !reduceMotion && !settled
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !canAnimate)) { context in
                    let t = min(context.date.timeIntervalSince(armedAt), Self.animateFor)
                    Canvas(rendersAsynchronously: true) { gc, size in
                        Particles.draw(kind, in: &gc, size: size, time: t + 1000)
                    }
                }
                .opacity(0.32)
                .allowsHitTesting(false)
                .task(id: "\(report?.location.id ?? "")-\(category.rawValue)") {
                    // Re-armed per location/condition; afterwards the timeline is paused (a still frame).
                    armedAt = Date()
                    settled = false
                    try? await Task.sleep(for: .seconds(Self.animateFor))
                    if !Task.isCancelled { settled = true }
                }
            }
            // Dim behind text: a soft vignette at the top where the hero sits.
            LinearGradient(colors: [.black.opacity(0.18), .clear, .black.opacity(0.12)], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }

    @State private var settled = false
}

/// Deterministic particle field (no per-particle state): position = f(seed, time).
enum Particles {
    enum Kind {
        case rain, drizzle, snow, storm
        init?(_ c: SkyCategory) {
            switch c {
            case .rain: self = .rain
            case .drizzle: self = .drizzle
            case .thunderstorm: self = .storm
            case .snow: self = .snow
            default: return nil
            }
        }
        var count: Int { switch self { case .rain: 90; case .drizzle: 60; case .storm: 120; case .snow: 70 } }
        var speed: Double { switch self { case .rain: 520; case .drizzle: 300; case .storm: 700; case .snow: 45 } }
    }

    static func draw(_ kind: Kind, in gc: inout GraphicsContext, size: CGSize, time: Double) {
        guard size.width > 0, size.height > 0 else { return }
        var path = Path()
        let h = Double(size.height) + 40, w = Double(size.width)
        for i in 0..<kind.count {
            let seed = Double(i) * 12.9898
            let r1 = fract(sin(seed) * 43758.5453), r2 = fract(sin(seed + 1.7) * 24634.6345), r3 = fract(sin(seed + 3.1) * 12345.678)
            let speed = kind.speed * (0.6 + 0.8 * r3)
            let y = (r2 * h + time * speed).truncatingRemainder(dividingBy: h) - 20
            switch kind {
            case .snow:
                let x = r1 * w + sin(time * 0.6 + seed) * 18
                path.addEllipse(in: CGRect(x: x, y: y, width: 2 + 3 * r3, height: 2 + 3 * r3))
            default:
                let x = (r1 * w + y * 0.12).truncatingRemainder(dividingBy: w)
                let len = kind == .drizzle ? 7 + 6 * r3 : 14 + 14 * r3
                path.move(to: CGPoint(x: x, y: y))
                path.addLine(to: CGPoint(x: x - len * 0.12, y: y - len))
            }
        }
        if kind == .snow {
            gc.fill(path, with: .color(.white.opacity(0.8)))
        } else {
            gc.stroke(path, with: .color(.white.opacity(0.55)), style: StrokeStyle(lineWidth: kind == .drizzle ? 0.8 : 1.1, lineCap: .round))
        }
    }

    private static func fract(_ x: Double) -> Double { x - x.rounded(.down) }
}
