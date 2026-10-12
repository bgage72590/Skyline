import Charts
import SwiftUI
import SkylineCore

/// L18: every model's temperature for the next 48 h on one chart, with the Skyline blend drawn on top,
/// so "the models disagree" can be seen rather than read. Collapsed to a one-line summary until opened,
/// so the chart (and its layers) only exists while someone is looking at it.
struct ModelComparisonCard: View {
    let report: WeatherReport
    let units: DisplayUnits
    @State private var expanded = false

    static let palette: [Color] = [
        Color(red: 0.55, green: 0.82, blue: 1.0), Color(red: 1.0, green: 0.72, blue: 0.40),
        Color(red: 0.62, green: 0.90, blue: 0.55), Color(red: 0.95, green: 0.55, blue: 0.75),
        Color(red: 0.78, green: 0.62, blue: 1.0), Color(red: 1.0, green: 0.88, blue: 0.45),
    ]

    var body: some View {
        let series = report.modelSeries
        if series.filter({ !$0.isBlend }).count >= 2 {
            Card(title: "Model Comparison", systemImage: "chart.xyaxis.line", subtitle: summary(series)) {
                VStack(alignment: .leading, spacing: 8) {
                    Button(expanded ? "Hide chart" : "Show each model, next 48 hours") {
                        withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                    }
                    .buttonStyle(.link)
                    .font(.callout)
                    if expanded {
                        chart(series)
                            .frame(height: 190)
                        legend(series)
                    }
                }
            }
        }
    }

    private func summary(_ series: [ModelSeries]) -> String {
        let spread = ModelSeries.spread(series).prefix(24)
        guard let widest = spread.max(by: { $0.spread < $1.spread }) else { return "" }
        let deg = Int(units.temperatureDelta(widest.spread).rounded())
        if deg <= 2 { return "The models agree within \(max(1, deg))° over the next day." }
        return "Widest split in the next day: \(deg)° around \(Fmt.hour(widest.time, report.timeZone))."
    }

    private func color(_ s: ModelSeries, _ all: [ModelSeries]) -> Color {
        if s.isBlend { return .white }
        let i = all.filter { !$0.isBlend }.firstIndex(of: s) ?? 0
        return Self.palette[i % Self.palette.count]
    }

    private func chart(_ series: [ModelSeries]) -> some View {
        Chart {
            ForEach(series) { s in
                ForEach(Array(zip(s.times, s.temperatures).enumerated()), id: \.offset) { _, point in
                    LineMark(x: .value("Time", point.0), y: .value("Temperature", units.temperature(point.1)),
                             series: .value("Model", s.name))
                        .foregroundStyle(color(s, series))
                        .lineStyle(StrokeStyle(lineWidth: s.isBlend ? 3 : 1.4, dash: s.name.hasPrefix("National") ? [4, 3] : []))
                        .interpolationMethod(.monotone)
                }
            }
        }
        .chartLegend(.hidden)
        .chartYScale(domain: .automatic(includesZero: false))
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 12)) { value in
                AxisGridLine().foregroundStyle(.white.opacity(0.15))
                AxisValueLabel { if let d = value.as(Date.self) { Text(Fmt.hour(d, report.timeZone)) } }
                    .foregroundStyle(Glass.secondaryText)
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine().foregroundStyle(.white.opacity(0.15))
                AxisValueLabel { if let v = value.as(Double.self) { Text("\(Int(v.rounded()))°") } }
                    .foregroundStyle(Glass.secondaryText)
            }
        }
        .accessibilityLabel("Temperature from each forecast model for the next 48 hours, with the Skyline blend")
    }

    private func legend(_ series: [ModelSeries]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 4) {
            ForEach(series) { s in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 1.5).fill(color(s, series)).frame(width: 14, height: s.isBlend ? 4 : 2)
                    Text(s.name).font(.caption).lineLimit(1)
                }
            }
        }
    }
}
