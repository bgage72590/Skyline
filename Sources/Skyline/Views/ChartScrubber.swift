import Charts
import SwiftUI

/// The shared scrubber callout (hourly/detail charts, nowcast chart and the radar timeline):
/// a small opaque bubble with the time on top and the value below.
struct ScrubCallout: View {
    let title: String
    var value: String? = nil

    var body: some View {
        VStack(spacing: 1) {
            Text(title).font(.caption2.weight(.semibold)).foregroundStyle(Glass.secondaryText)
            if let value { Text(value).font(.callout.weight(.semibold)).monospacedDigit() }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(red: 0.12, green: 0.14, blue: 0.19).opacity(0.96), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
        .fixedSize()
    }
}

/// Apple-style chart scrubbing for time-series charts: hover (or drag) moves a selection that snaps to
/// the data's timestamps; ←/→ move it one step when the chart has keyboard focus.
/// The chart draws the rule + `ScrubCallout` itself from the `selection` binding.
/// State is written only from pointer/keyboard events, never from layout.
struct ChartScrubber: ViewModifier {
    let times: [Date]
    @Binding var selection: Date?
    @Environment(WeatherStore.self) private var store
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let point): select(at: point, proxy: proxy, geo: geo)
                            case .ended: if !focused, selection != nil { selection = nil }
                            }
                        }
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    if !store.isScrubbing { store.isScrubbing = true }
                                    focused = true
                                    select(at: value.location, proxy: proxy, geo: geo)
                                }
                                .onEnded { _ in if store.isScrubbing { store.isScrubbing = false } }
                        )
                }
            }
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.leftArrow) { step(-1); return .handled }
            .onKeyPress(.rightArrow) { step(1); return .handled }
            .onKeyPress(.escape) {
                guard selection != nil else { return .ignored }
                selection = nil
                return .handled
            }
    }

    private func select(at point: CGPoint, proxy: ChartProxy, geo: GeometryProxy) {
        guard let plot = proxy.plotFrame else { return }
        let x = point.x - geo[plot].origin.x
        guard let date: Date = proxy.value(atX: x) else { return }
        let snapped = nearest(date)
        if snapped != selection { selection = snapped }
    }

    private func nearest(_ date: Date) -> Date? {
        times.min { abs($0.timeIntervalSince(date)) < abs($1.timeIntervalSince(date)) }
    }

    private func step(_ delta: Int) {
        guard !times.isEmpty else { return }
        let current = selection.flatMap { s in times.firstIndex(of: s) }
            ?? times.firstIndex { $0 >= Date() }.map { $0 - (delta > 0 ? 1 : 0) }
            ?? 0
        let next = min(max(current + delta, 0), times.count - 1)
        selection = times[next]
    }
}

extension View {
    func chartScrubber(times: [Date], selection: Binding<Date?>) -> some View {
        modifier(ChartScrubber(times: times, selection: selection))
    }
}
