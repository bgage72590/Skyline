import Charts
import SwiftUI
import SkylineCore

/// Tile in the grid: either "Collecting data" with progress, or the blend's verified error.
struct AccuracyTile: View {
    let location: WeatherLocation
    let units: DisplayUnits
    @Environment(WeatherStore.self) private var store

    var body: some View {
        let r = store.accuracy[location.id]
        Tile(title: r?.isDemo == true ? "Accuracy · Demo" : "Accuracy", systemImage: "scope") {
            if let r, r.status == .ready, let mae = r.overall[.blend]?.tempMAE {
                TileValue(value: "±\(AccuracyFormat.delta(mae, units))",
                          label: "Typical temp. error",
                          detail: r.recentWinner.map { "\($0.displayName) leading lately. \(AccuracyFormat.days(r.daysCollected)) of data." }
                            ?? "\(AccuracyFormat.days(r.daysCollected)) of verified forecasts.")
            } else {
                TileValue(value: "Collecting",
                          label: r.map { "\(AccuracyFormat.days($0.daysCollected)) of \(Int($0.minDays)) days" } ?? "Starting",
                          detail: "Skyline checks its forecasts against the \(AccuracyStationCopy.stationPhrase(isUS: location.isLikelyInNWSCoverage)) and learns which model is best here.")
            }
        }
    }
}

enum AccuracyFormat {
    static func delta(_ c: Double, _ units: DisplayUnits) -> String {
        String(format: "%.1f°", units.temperatureDelta(c))
    }
    /// "1.9°F"
    static func deltaWithUnit(_ c: Double, _ units: DisplayUnits) -> String {
        String(format: "%.1f", units.temperatureDelta(c)) + units.temperature.label
    }
    static func signed(_ c: Double, _ units: DisplayUnits) -> String {
        String(format: "%+.1f°", units.temperatureDelta(c))
    }
    static func percent(_ v: Double?) -> String { v.map { "\(Int(($0 * 100).rounded()))%" } ?? "—" }
    static func days(_ d: Double) -> String {
        d < 1 ? "\(max(1, Int((d * 24).rounded()))) h" : (d < 10 ? String(format: "%.1f days", d) : "\(Int(d.rounded())) days")
    }
}

/// Body of the Forecast Accuracy detail (inspector column or panel).
struct AccuracyPanel: View {
    let location: WeatherLocation
    let units: DisplayUnits
    @Environment(WeatherStore.self) private var store
    @State private var bucket: LeadBucket?
    @State private var showDetails = false
    @State private var benchmark: BenchmarkSummary?
    @State private var correctionLines: [CorrectionStatus] = []

    var body: some View {
        let r = store.accuracy[location.id]
        VStack(alignment: .leading, spacing: 14) {
            if r?.isDemo == true {
                Label("DEMO DATA: illustrative numbers for screenshots, not real verification", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.yellow, in: Capsule())
            }
            // One plain-English sentence first (T9); the numbers and jargon sit behind Details.
            Text(r.map { AccuracySummary.headline($0, delta: { AccuracyFormat.deltaWithUnit($0, units) }) }
                 ?? "Skyline is checking its forecasts against what the nearest weather station measures. The first results appear once a few hours have been verified.")
                .font(.title3.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            if let r {
                if r.verifiedPairs > 0 {
                    Text(AccuracyCorrectionCopy.scoresCaption)
                        .font(.caption)
                        .foregroundStyle(Glass.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if r.status == .collecting { collecting(r) }
                if r.verifiedPairs > 0 { scores(r) }
            } else {
                collecting(nil)
            }
            benchmarkSection()
            correctionSection
            Text("How it works: every few hours Skyline saves what each source predicted for this place, then compares it with what the \(AccuracyStationCopy.stationPhrase(isUS: location.isLikelyInNWSCoverage)) measured. Typical error is the mean absolute difference; rain calls count hours with ≥ 50 % chance (or ≥ 0.2 mm) against hours the station reported precipitation. Once there are \(Int(r?.minDays ?? 3))+ days of pairs, the blend gives more weight to the sources that have been most accurate here, and never drops any source entirely.\(AccuracyCorrectionCopy.howItWorksSuffix)")
                .font(.caption)
                .foregroundStyle(Glass.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task(id: location.id) {
            await store.refreshAccuracy(for: location)
            let key = VerificationKey.key(for: location)
            benchmark = await store.service.verifier?.benchmarkSummary(key)
            if let v = store.service.verifier {
                // Read-only (L8): the panel never refreshes correction state (rate limit / appliedOn) and never
                // falls back to the Mac's time zone. Statuses are built by the verifier in the city's zone.
                let raw = await v.correctionStatuses(key)
                let qaActive = await v.isQAOverrideActive
                correctionLines = raw.map { s in
                    var copy = s
                    // Show delta in the user's unit (×1.8 for °F, never +32) — B10.
                    copy = CorrectionStatus(
                        loc: s.loc, target: s.target,
                        line: BiasCorrection.statusLine(
                            entry: CorrectionEntry(loc: s.loc, target: s.target, appliedC: s.appliedC,
                                                   autoOff: s.autoOff),
                            gated: s.gated, sitingOK: s.sitingOK,
                            switchOn: SkylineAccuracyCorrection.isEnabled(),
                            nDays: s.nDays,
                            units: { units.temperatureDelta($0) },
                            qaOverride: qaActive,
                            target: s.target, nPairs: s.nPairs,
                            stationPending: s.line == BiasCorrection.offStationPending),
                        appliedC: s.appliedC, nDays: s.nDays, nPairs: s.nPairs, gated: s.gated,
                        autoOff: s.autoOff, sitingOK: s.sitingOK)
                    return copy
                }
            }
        }
    }

    /// Accuracy PR 2: one line per city × target (lock §2).
    @ViewBuilder
    private var correctionSection: some View {
        if !correctionLines.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("BIAS CORRECTION")
                    .font(.caption2.weight(.semibold)).foregroundStyle(Glass.secondaryText)
                ForEach(correctionLines, id: \.target) { s in
                    HStack {
                        Text(s.target.displayName).font(.callout.weight(.semibold))
                        Spacer()
                        Text(s.line).font(.caption.monospacedDigit())
                            .foregroundStyle(Glass.secondaryText)
                    }
                    .padding(.vertical, 1)
                }
                // Only while a line is actually paused: auto-off, switch on, and siting OK.
                // "off: switched off" and "off: station" take precedence, so no footnote then.
                if SkylineAccuracyCorrection.isEnabled(),
                   correctionLines.contains(where: { $0.autoOff && $0.sitingOK }) {
                    Text(AccuracyCorrectionCopy.autoOffFootnote)
                        .font(.caption2)
                        .foregroundStyle(Glass.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    /// Accuracy PR 1: measurement-only comparison. Hourly temperature MAE and daily high/low MAE are
    /// separate lists (never mix MET daily-high with Skyline/NWS/Best Match hourly).
    @ViewBuilder
    private func benchmarkSection() -> some View {
        let hourly = hourlyBenchmarkRows()
        let daily = dailyBenchmarkRows()
        if !hourly.isEmpty || !daily.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Skyline vs other forecasts")
                    .font(.title2.weight(.semibold))
                Text("How Skyline’s forecast compares with other free forecasts at this place. Hidden until there are at least 20 verified samples.")
                    .font(.caption).foregroundStyle(Glass.secondaryText)
                if !hourly.isEmpty {
                    Text("HOURLY TEMPERATURE (TYPICAL ERROR)")
                        .font(.caption2.weight(.semibold)).foregroundStyle(Glass.secondaryText)
                    ForEach(hourly, id: \.title) { row in
                        HStack {
                            Text(row.title).font(.callout.weight(.semibold))
                            Spacer()
                            Text(row.value).font(.callout.monospacedDigit())
                        }
                        .padding(.vertical, 2)
                    }
                    if let paired = benchmark?.pairedHourly {
                        Text("Compared on the same \(paired.n) hours (last \(Int(paired.windowDays)) days)")
                            .font(.caption).foregroundStyle(Glass.secondaryText)
                    }
                }
                if !daily.isEmpty {
                    Text("DAILY HIGH / LOW (TYPICAL ERROR)")
                        .font(.caption2.weight(.semibold)).foregroundStyle(Glass.secondaryText)
                        .padding(.top, hourly.isEmpty ? 0 : 4)
                    ForEach(daily, id: \.title) { row in
                        HStack {
                            Text(row.title).font(.callout.weight(.semibold))
                            Spacer()
                            Text(row.value).font(.callout.monospacedDigit())
                        }
                        .padding(.vertical, 2)
                    }
                }
                if let b = benchmark {
                    if let id = b.stationID {
                        let dist = b.stationDistanceKm.map { String(format: " · %.0f km", $0) } ?? ""
                        Text("Station: \(b.stationName ?? id) (\(id))\(dist)")
                            .font(.caption).foregroundStyle(Glass.secondaryText)
                    }
                    if BenchmarkScorer.showsMetNorwayRow(b) {
                        Text(b.metNorwayAttribution)
                            .font(.caption2).foregroundStyle(Glass.secondaryText)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private struct BenchRow: Hashable {
        var title: String
        var value: String
    }

    /// Hourly temperature MAE on one shared set of hours. The main-card AccuracyReport is not mixed in.
    private func hourlyBenchmarkRows() -> [BenchRow] {
        guard let paired = benchmark?.pairedHourly, paired.n >= 20 else { return [] }
        let order: [BenchmarkForecastKind] = [.skyline, .metNorway, .nws, .bestMatch]
        return order.compactMap { kind in
            guard let mae = paired.kinds[kind] else { return nil }
            return BenchRow(title: kind.displayName, value: "±" + AccuracyFormat.delta(mae, units))
        }
    }

    /// Daily high/low MAE from the isolated store for all four kinds (same metric, same issues).
    private func dailyBenchmarkRows() -> [BenchRow] {
        guard let b = benchmark else { return [] }
        var out: [BenchRow] = []
        for kind in BenchmarkForecastKind.allCases {
            guard let row = b.rows.first(where: { $0.kind == kind }), row.dailyN >= 20 else { continue }
            let high = row.highMAE.map { "H ±" + AccuracyFormat.delta($0, units) }
            let low = row.lowMAE.map { "L ±" + AccuracyFormat.delta($0, units) }
            let parts = [high, low].compactMap { $0 }
            guard !parts.isEmpty else { continue }
            out.append(BenchRow(title: kind.displayName, value: parts.joined(separator: " · ")))
        }
        return out
    }

    // MARK: Collecting

    private func collecting(_ r: AccuracyReport?) -> some View {
        let days = r?.daysCollected ?? 0
        let need = r?.minDays ?? 3
        return VStack(alignment: .leading, spacing: 8) {
            Text("Collecting data").font(.title2.weight(.semibold))
            ProgressView(value: min(days / need, 1))
                .tint(Color(red: 0.45, green: 0.8, blue: 1))
            Text("\(AccuracyFormat.days(days)) of \(Int(need)) days · \(r?.verifiedPairs ?? 0) forecast checks · \(r?.pendingForecasts ?? 0) waiting for observations")
                .font(.callout).monospacedDigit()
            if !location.isLikelyInNWSCoverage, let id = benchmark?.stationID {
                Text(AccuracyStationCopy.stationLine(name: benchmark?.stationName, stationID: id,
                                                    distanceKm: benchmark?.stationDistanceKm))
                    .font(.caption).foregroundStyle(Glass.secondaryText)
            } else if let id = r?.stationID {
                Text("Station: \(r?.stationName ?? id) (\(id))").font(.caption).foregroundStyle(Glass.secondaryText)
            } else if let line = AccuracyStationCopy.collectingUnavailableLine(
                isUS: location.isLikelyInNWSCoverage, benchmarkStationID: benchmark?.stationID) {
                Text(line).font(.caption).foregroundStyle(Glass.secondaryText)
            }
            Text("Until then the blend uses Skyline's standard weights. Early numbers below are based on few samples.")
                .font(.caption).foregroundStyle(Glass.secondaryText)
                .opacity((r?.verifiedPairs ?? 0) > 0 ? 1 : 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: Scores

    private func table(_ r: AccuracyReport) -> [SourceScore] {
        let base = bucket.flatMap { r.byBucket[$0] } ?? (bucket == nil ? r.overall : [:])
        return base.values.filter { $0.tempN > 0 || $0.rainN > 0 }
            .sorted { ($0.tempMAE ?? .infinity) < ($1.tempMAE ?? .infinity) }
    }

    @ViewBuilder
    private func scores(_ r: AccuracyReport) -> some View {
        let blend = (bucket.flatMap { r.byBucket[$0] } ?? r.overall)[.blend]
        // Headline numbers.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
            stat("Typical temp. miss", blend?.tempMAE.map { "±" + AccuracyFormat.delta($0, units) } ?? "—",
                 blend?.tempBiasMean.map { "Bias " + AccuracyFormat.signed($0, units) } ?? "")
            stat("Rain hours caught", AccuracyFormat.percent(blend?.hitRate),
                 blend?.falseAlarmRatio.map { "\(AccuracyFormat.percent($0)) false alarms" } ?? "No wet hours yet")
            stat("Winning lately", r.recentWinner?.displayName ?? "Too early",
                 r.recentWinnerMAE.map { "±" + AccuracyFormat.delta($0, units) + " · last 7 days" } ?? "Needs a few days")
            stat("Data collected", AccuracyFormat.days(r.daysCollected), "\(r.verifiedPairs) forecast checks")
        }

        Picker("Lead time", selection: $bucket) {
            Text("All").tag(LeadBucket?.none)
            ForEach(LeadBucket.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()

        let rows = table(r)
        if rows.isEmpty {
            Text("No verified forecasts at this lead time yet.").font(.callout).foregroundStyle(Glass.secondaryText)
        } else {
            maeChart(rows)
            DisclosureGroup("Details: every source, rain scores and the weights in use", isExpanded: $showDetails) {
                VStack(alignment: .leading, spacing: 10) {
                    sourceTable(rows)
                    weightsRow(r)
                }
                .padding(.top, 6)
            }
            .font(.callout)
            .tint(.white)
        }
    }

    private func stat(_ title: String, _ value: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(Glass.secondaryText)
            Text(value).font(.title2.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.6).monospacedDigit()
            Text(detail).font(.caption).foregroundStyle(Glass.secondaryText).lineLimit(1).minimumScaleFactor(0.8)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func maeChart(_ rows: [SourceScore]) -> some View {
        let data = rows.compactMap { s in s.tempMAE.map { (name: s.source.displayName, mae: units.temperatureDelta($0), blend: s.source == .blend) } }
        return VStack(alignment: .leading, spacing: 4) {
            Text("TYPICAL TEMPERATURE ERROR (LOWER IS BETTER)").font(.caption2.weight(.semibold)).foregroundStyle(Glass.secondaryText)
            Chart(data, id: \.name) { d in
                BarMark(x: .value("Error", d.mae), y: .value("Source", d.name))
                    .foregroundStyle(d.blend ? Color(red: 0.45, green: 0.82, blue: 1) : Color.white.opacity(0.35))
                    .cornerRadius(3)
                    .annotation(position: .trailing, spacing: 4) {
                        Text(String(format: "±%.1f°", d.mae)).font(.caption2.weight(.semibold)).monospacedDigit()
                    }
            }
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks { _ in AxisValueLabel().foregroundStyle(.white) }
            }
            .frame(height: CGFloat(data.count) * 24 + 8)
        }
    }

    @ViewBuilder
    private func sourceTable(_ rows: [SourceScore]) -> some View {
        Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 6) {
            GridRow {
                Text("Source").gridColumnAlignment(.leading)
                Text("Temp"); Text("Bias"); Text("Wind"); Text("Rain caught"); Text("False alarms"); Text("Brier"); Text("Hours")
            }
            .font(.caption2.weight(.semibold)).foregroundStyle(Glass.secondaryText)
            ForEach(rows, id: \.source) { s in
                GridRow {
                    Text(s.source.displayName).fontWeight(s.source == .blend ? .bold : .regular)
                    Text(s.tempMAE.map { "±" + AccuracyFormat.delta($0, units) } ?? "—")
                    Text(s.tempBiasMean.map { AccuracyFormat.signed($0, units) } ?? "—")
                    Text(s.windMAE.map { String(format: "±%.1f", units.speed($0)) } ?? "—")
                    Text(AccuracyFormat.percent(s.hitRate))
                    Text(AccuracyFormat.percent(s.falseAlarmRatio))
                    Text(s.brier.map { String(format: "%.2f", $0) } ?? "—")
                    Text("\(Int(max(s.tempN, s.rainN).rounded()))").foregroundStyle(Glass.secondaryText)
                }
                .font(.caption).monospacedDigit()
            }
        }
        .padding(10)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        Text("Temp and wind: typical error (wind in \(units.speedUnit)). Bias: + means forecasts ran warm. Hours: recent-weighted hours checked. Brier: rain-probability score, lower is better (only sources that give a probability). Where Best Match is a copy of GFS or HRRR, the table scores it only on the hours it differs from them, so it can look worse than it is; the learned weights use every hour.")
            .font(.caption2).foregroundStyle(Glass.secondaryText)
    }

    @ViewBuilder
    private func weightsRow(_ r: AccuracyReport) -> some View {
        let lead: Double = switch bucket { case .h0to6?: 3; case .h6to24?: 12; case .day2?: 36; case .day3plus?: 72; case nil: 12 }
        let shown = VerificationSource.inputs.map { ($0, r.weights.multiplier(.temperature, $0, leadHours: lead)) }
        VStack(alignment: .leading, spacing: 6) {
            Text("TEMPERATURE WEIGHTS IN USE (\((bucket ?? .h6to24).label.uppercased()))")
                .font(.caption2.weight(.semibold)).foregroundStyle(Glass.secondaryText)
            if shown.allSatisfy({ $0.1 == 1 }) {
                Text("Standard weights: not enough verified data at this lead time yet.").font(.caption)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 6) {
                    ForEach(shown, id: \.0) { src, m in
                        Text("\(src.displayName) ×\(String(format: "%.2f", m))")
                            .font(.caption.weight(.semibold)).monospacedDigit()
                            .lineLimit(1).fixedSize()
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background((m > 1.05 ? Color.green : (m < 0.95 ? Color.orange : Color.white)).opacity(0.18), in: Capsule())
                    }
                }
            }
        }
    }
}

/// Clearly labelled demo numbers for screenshots (`-SkylineDemoAccuracy YES`). Never used otherwise.
enum AccuracyDemo {
    static func report() -> AccuracyReport {
        func score(_ s: VerificationSource, mae: Double, bias: Double, wind: Double, hits: Double, misses: Double,
                   fa: Double, cn: Double, brier: Double?, n: Double) -> SourceScore {
            var x = SourceScore(source: s)
            x.tempN = n; x.tempAbs = mae * n; x.tempBias = bias * n
            x.windN = n; x.windAbs = wind * n
            x.hits = hits; x.misses = misses; x.falseAlarms = fa; x.correctNegatives = cn
            if let brier { x.brierN = n; x.brierSum = brier * n }
            return x
        }
        let overall: [VerificationSource: SourceScore] = [
            .blend: score(.blend, mae: 1.05, bias: 0.1, wind: 4.1, hits: 41, misses: 7, fa: 9, cn: 263, brier: 0.071, n: 320),
            .hrrr: score(.hrrr, mae: 1.12, bias: -0.2, wind: 4.6, hits: 40, misses: 8, fa: 12, cn: 260, brier: nil, n: 320),
            .nws: score(.nws, mae: 1.21, bias: 0.4, wind: 4.4, hits: 38, misses: 10, fa: 8, cn: 264, brier: 0.078, n: 320),
            .bestMatch: score(.bestMatch, mae: 1.34, bias: 0.3, wind: 4.9, hits: 37, misses: 11, fa: 11, cn: 261, brier: 0.084, n: 320),
            .ecmwf: score(.ecmwf, mae: 1.41, bias: 0.6, wind: 5.2, hits: 35, misses: 13, fa: 10, cn: 262, brier: nil, n: 320),
            .icon: score(.icon, mae: 1.63, bias: -0.5, wind: 5.6, hits: 33, misses: 15, fa: 14, cn: 258, brier: nil, n: 320),
            .gfs: score(.gfs, mae: 1.88, bias: -0.9, wind: 6.0, hits: 36, misses: 12, fa: 21, cn: 251, brier: nil, n: 320),
        ]
        var weights = BlendWeights()
        weights.multipliers[.temperature] = [.h6to24: [.hrrr: 1.28, .nws: 1.16, .bestMatch: 1.04, .ecmwf: 0.98, .icon: 0.86, .gfs: 0.71]]
        return AccuracyReport(status: .ready, daysCollected: 14.2, verifiedPairs: 2_310, pendingForecasts: 118,
                              stationID: "KDEMO", stationName: "Demo Station", overall: overall,
                              byBucket: [.h6to24: overall], recentWinner: .hrrr, recentWinnerMAE: 1.08,
                              weights: weights, minDays: 3, isDemo: true)
    }
}
