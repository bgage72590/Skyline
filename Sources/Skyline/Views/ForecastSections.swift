import Charts
import SwiftUI
import SkylineCore

/// Pinned plain-English summary at the top of the forecast column: stays put while the hero
/// above it shrinks away, so "what's happening" is always one glance away.
struct BriefingBar: View {
    let report: WeatherReport
    let units: UnitPreference

    var body: some View {
        let tz = report.timeZone
        let text = Briefing.headline(report, now: report.current.time,
                                     hourLabel: { Fmt.hour($0, tz) },
                                     delta: { Int(units.temperatureDelta($0).rounded()) })
        HStack(alignment: .center, spacing: 10) {
            WeatherSymbol(condition: report.current.condition, isDay: report.current.isDay, size: 18)
            Text(units.temperatureString(report.current.temperature))
                .font(.title3.weight(.semibold)).monospacedDigit()
            Text(text)
                .font(.callout.weight(.medium))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassCard(cornerRadius: 14)
        .accessibilityElement(children: .combine)
    }
}

/// Severity-coloured alert banner in the main view (not just the sidebar). Links to the outline on
/// the radar map and to the full NWS text.
struct AlertBanner: View {
    let alerts: [WeatherAlert]
    let timeZone: TimeZone
    @Environment(WeatherStore.self) private var store
    @Environment(\.isWideLayout) private var isWide
    @State private var detail: WeatherAlert?

    var body: some View {
        let top = alerts[0]
        let color = AlertsCard.color(top.severity)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title3)
                    .foregroundStyle(color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(top.event + (alerts.count > 1 ? "  +\(alerts.count - 1) more" : ""))
                        .font(.headline)
                    if let until = top.ends ?? top.expires {
                        Text("Until \(Fmt.dayTime(until, timeZone))\(top.senderName.map { " · \($0)" } ?? "")")
                            .font(.caption).foregroundStyle(Glass.secondaryText)
                    }
                    if let headline = top.headline {
                        Text(headline).font(.caption).lineLimit(2).foregroundStyle(.white)
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                if !top.polygons.isEmpty {
                    Button { store.showAlertOnMap(top, wideLayout: isWide) } label: {
                        Label("Show on Map", systemImage: "map")
                    }
                }
                Button { detail = top } label: { Label("Full Alert", systemImage: "doc.text") }
                if alerts.count > 1 {
                    Menu("Others") {
                        ForEach(alerts.dropFirst()) { a in
                            Button(a.event) { detail = a }
                        }
                    }
                    .fixedSize()
                }
            }
            .buttonStyle(.borderless)
            .font(.caption.weight(.semibold))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
            ZStack {
                shape.fill(Color(red: 0.08, green: 0.08, blue: 0.10).opacity(0.85))
                shape.fill(color.opacity(0.22))
            }
        }
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 14, style: .continuous)
                .fill(color).frame(width: 5)
        }
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(color.opacity(0.7), lineWidth: 1))
        .sheet(item: $detail) { alert in
            AlertDetailView(alert: alert, timeZone: timeZone) {
                store.showAlertOnMap(alert, wideLayout: isWide)
            }
        }
    }
}

/// Next-two-hours precipitation from the 15-minute nowcast. Shown only when rain is actually due.
struct NowcastCard: View {
    let report: WeatherReport
    let units: UnitPreference
    @State private var scrub: Date?

    var body: some View {
        let now = report.current.time
        let rows = report.minutely.filter { $0.time >= now.addingTimeInterval(-15 * 60) && $0.time <= now.addingTimeInterval(2 * 3600) }
        let maxValue = max(rows.map(\.precipitation).max() ?? 0, 1.0)
        let selected = scrub.flatMap { s in rows.first { $0.time == s } }
        Card(title: "Next 2 Hours", systemImage: "cloud.rain.fill", subtitle: report.nowcastSummary.map { $0 + "." }) {
            Chart {
                ForEach(rows, id: \.time) { r in
                    BarMark(x: .value("Time", r.time, unit: .minute), y: .value("mm", r.precipitation), width: .ratio(0.7))
                        .foregroundStyle(Color(red: 0.4, green: 0.75, blue: 1.0).gradient)
                        .cornerRadius(2)
                }
                if let selected {
                    RuleMark(x: .value("Selected", selected.time))
                        .foregroundStyle(.white.opacity(0.8))
                        .annotation(position: .top, spacing: 2, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                            ScrubCallout(title: Fmt.time(selected.time, report.timeZone),
                                         value: intensity(selected.precipitation))
                        }
                }
            }
            .chartYScale(domain: 0...(maxValue * 1.5))
            .chartYAxis {
                AxisMarks(values: [0, maxValue / 2, maxValue]) { v in
                    AxisGridLine().foregroundStyle(.white.opacity(0.12))
                    AxisValueLabel { Text(v.index == 0 ? "" : (v.index == 1 ? "Light" : "Heavy")) }
                        .foregroundStyle(Glass.secondaryText)
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .minute, count: 30)) { _ in
                    AxisValueLabel(format: .dateTime.hour().minute()).foregroundStyle(Glass.secondaryText)
                }
            }
            .chartScrubber(times: rows.map(\.time), selection: $scrub)
            .environment(\.timeZone, report.timeZone)
            .frame(height: 110)
        }
    }

    private func intensity(_ mm15: Double) -> String {
        let perHour = mm15 * 4
        let label = perHour < 0.4 ? "None" : (perHour < 2.5 ? "Light" : (perHour < 7.6 ? "Moderate" : "Heavy"))
        return "\(label) · \(units.precipitationString(perHour))/h"
    }
}
