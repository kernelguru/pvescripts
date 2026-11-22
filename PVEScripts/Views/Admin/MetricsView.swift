import SwiftUI
import Charts

// MARK: - Daten

struct RRDPoint: Identifiable {
    let date: Date
    let values: [String: Double]
    var id: Date { date }
    subscript(_ key: String) -> Double? { values[key] }
}

enum MetricsTimeframe: String, CaseIterable, Identifiable {
    case hour, day, week, month, year
    var id: String { rawValue }
    var title: String {
        switch self {
        case .hour: "Stunde"
        case .day: "Tag"
        case .week: "Woche"
        case .month: "Monat"
        case .year: "Jahr"
        }
    }
}

enum MetricsScope {
    case node(String)
    case guest(ProxmoxGuest)

    var path: String {
        switch self {
        case .node(let name): "/nodes/\(name)/rrddata"
        case .guest(let guest): "\(guest.apiPath)/rrddata"
        }
    }

    var title: String {
        switch self {
        case .node(let name): "Node \(name)"
        case .guest(let guest): guest.displayName
        }
    }

    var isNode: Bool { if case .node = self { return true } else { return false } }
}

extension PVEClient {
    func rrdData(_ scope: MetricsScope, timeframe: MetricsTimeframe, maximum: Bool) async throws -> [RRDPoint] {
        let json = try await getJSON(scope.path, [("timeframe", timeframe.rawValue), ("cf", maximum ? "MAX" : "AVERAGE")])
        return json.arrayValue.compactMap { entry -> RRDPoint? in
            guard case .object(let object) = entry, let time = object["time"]?.doubleValue else { return nil }
            var values: [String: Double] = [:]
            for (key, value) in object where key != "time" {
                if let number = value.doubleValue, number.isFinite { values[key] = number }
            }
            // Leere Zeilen (z. B. Gast war aus) überspringen, damit keine falschen Nullen entstehen.
            guard !values.isEmpty else { return nil }
            return RRDPoint(date: Date(timeIntervalSince1970: time), values: values)
        }
        .sorted { $0.date < $1.date }
    }
}

// MARK: - Farben (validierte Palette, hell/dunkel)

enum ChartPalette {
    static let series1 = dynamic(light: 0x2a78d6, dark: 0x3987e5)  // Blau
    static let series2 = dynamic(light: 0xeb6834, dark: 0xd95926)  // Orange
    static let reference = Color.secondary

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 0xff) / 255,
                           green: CGFloat((hex >> 8) & 0xff) / 255,
                           blue: CGFloat(hex & 0xff) / 255, alpha: 1)
        })
    }
}

// MARK: - Diagramm-Definition

enum MetricUnit {
    case percent, bytes, bytesPerSecond, plain

    func format(_ value: Double) -> String {
        switch self {
        case .percent: return String(format: value < 0.1 ? "%.1f %%" : "%.0f %%", value * 100)
        case .bytes: return Fmt.bytes(value)
        case .bytesPerSecond: return value < 1 ? "0 B/s" : "\(Fmt.bytes(value))/s"
        case .plain: return String(format: "%.2f", value)
        }
    }
}

struct MetricSeries {
    let key: String
    let name: String
    let color: Color
    /// Optional: Wert umrechnen (z. B. used/total).
    var transform: ((RRDPoint) -> Double?)? = nil

    func value(_ point: RRDPoint) -> Double? { transform?(point) ?? point[key] }
}

struct MetricChartSpec: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let unit: MetricUnit
    let series: [MetricSeries]
    /// Gestrichelte Referenzlinie, z. B. Gesamt-RAM.
    var referenceKey: String? = nil
    var referenceName: String? = nil
    var yMax: Double? = nil
}

extension MetricsScope {
    var charts: [MetricChartSpec] {
        switch self {
        case .node:
            return [
                MetricChartSpec(id: "cpu", title: "CPU", symbol: "cpu", unit: .percent, series: [
                    MetricSeries(key: "cpu", name: "CPU", color: ChartPalette.series1),
                    MetricSeries(key: "iowait", name: "IO-Wait", color: ChartPalette.series2),
                ], yMax: 1),
                MetricChartSpec(id: "load", title: "Load", symbol: "gauge.with.dots.needle.33percent", unit: .plain, series: [
                    MetricSeries(key: "loadavg", name: "Load", color: ChartPalette.series1),
                ]),
                MetricChartSpec(id: "mem", title: "Arbeitsspeicher", symbol: "memorychip", unit: .bytes, series: [
                    MetricSeries(key: "memused", name: "Belegt", color: ChartPalette.series1),
                ], referenceKey: "memtotal", referenceName: "Gesamt"),
                MetricChartSpec(id: "net", title: "Netzwerk", symbol: "network", unit: .bytesPerSecond, series: [
                    MetricSeries(key: "netin", name: "Eingang", color: ChartPalette.series1),
                    MetricSeries(key: "netout", name: "Ausgang", color: ChartPalette.series2),
                ]),
                MetricChartSpec(id: "root", title: "Root-Disk", symbol: "internaldrive", unit: .bytes, series: [
                    MetricSeries(key: "rootused", name: "Belegt", color: ChartPalette.series1),
                ], referenceKey: "roottotal", referenceName: "Gesamt"),
            ]
        case .guest(let guest):
            var specs = [
                MetricChartSpec(id: "cpu", title: "CPU", symbol: "cpu", unit: .percent, series: [
                    MetricSeries(key: "cpu", name: "CPU", color: ChartPalette.series1),
                ], yMax: 1),
                MetricChartSpec(id: "mem", title: "Arbeitsspeicher", symbol: "memorychip", unit: .bytes, series: [
                    MetricSeries(key: "mem", name: "Belegt", color: ChartPalette.series1),
                ], referenceKey: "maxmem", referenceName: "Zugewiesen"),
                MetricChartSpec(id: "net", title: "Netzwerk", symbol: "network", unit: .bytesPerSecond, series: [
                    MetricSeries(key: "netin", name: "Eingang", color: ChartPalette.series1),
                    MetricSeries(key: "netout", name: "Ausgang", color: ChartPalette.series2),
                ]),
                MetricChartSpec(id: "io", title: "Disk-I/O", symbol: "externaldrive", unit: .bytesPerSecond, series: [
                    MetricSeries(key: "diskread", name: "Lesen", color: ChartPalette.series1),
                    MetricSeries(key: "diskwrite", name: "Schreiben", color: ChartPalette.series2),
                ]),
            ]
            if guest.kind == .lxc {
                specs.append(MetricChartSpec(id: "disk", title: "Root-Disk", symbol: "internaldrive", unit: .bytes, series: [
                    MetricSeries(key: "disk", name: "Belegt", color: ChartPalette.series1),
                ], referenceKey: "maxdisk", referenceName: "Größe"))
            }
            return specs
        }
    }
}

// MARK: - Ansicht

struct MetricsView: View {
    let client: PVEClient
    let scope: MetricsScope

    @State private var timeframe: MetricsTimeframe = .hour
    @State private var maximum = false
    @State private var points: [RRDPoint] = []
    @State private var loading = false
    @State private var error: String?
    /// Gemeinsamer Zeitpunkt für das Fadenkreuz in allen Diagrammen.
    @State private var selectedDate: Date?

    var body: some View {
        List {
            Section {
                Picker("Zeitraum", selection: $timeframe) {
                    ForEach(MetricsTimeframe.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Werte", selection: $maximum) {
                    Text("Durchschnitt").tag(false)
                    Text("Maximum").tag(true)
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("Zum Ablesen auf ein Diagramm tippen oder darüber wischen.")
            }

            if let error {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            }

            if points.isEmpty {
                Section {
                    if loading {
                        ProgressView().frame(maxWidth: .infinity)
                    } else if error == nil {
                        Text("Für diesen Zeitraum liegen keine Daten vor.").foregroundStyle(.secondary)
                    }
                }
            } else {
                ForEach(scope.charts) { spec in
                    Section {
                        MetricChart(spec: spec, points: points, timeframe: timeframe, selectedDate: $selectedDate)
                    }
                }
            }
        }
        .navigationTitle("Verlauf")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task(id: "\(timeframe.rawValue)-\(maximum)") {
            await load()
            // Stundenansicht jede Minute aktualisieren.
            while timeframe == .hour && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                if Task.isCancelled { break }
                await load(silent: true)
            }
        }
    }

    private func load(silent: Bool = false) async {
        if !silent { loading = true }
        defer { loading = false }
        do {
            points = try await client.rrdData(scope, timeframe: timeframe, maximum: maximum)
            error = nil
        } catch {
            if !silent { self.error = error.localizedDescription }
        }
    }
}

/// Ein Liniendiagramm mit Kopfzeile, Legende mit aktuellen Werten und Fadenkreuz.
struct MetricChart: View {
    let spec: MetricChartSpec
    let points: [RRDPoint]
    let timeframe: MetricsTimeframe
    @Binding var selectedDate: Date?

    private struct Sample: Identifiable {
        let date: Date
        let series: String
        let value: Double
        var id: String { "\(series)-\(date.timeIntervalSince1970)" }
    }

    private var samples: [Sample] {
        points.flatMap { point in
            spec.series.compactMap { s in s.value(point).map { Sample(date: point.date, series: s.name, value: $0) } }
        }
    }

    private var reference: Double? {
        guard let key = spec.referenceKey else { return nil }
        return points.last(where: { $0[key] != nil })?[key]
    }

    /// Punkt, der dem gewählten Zeitpunkt am nächsten liegt.
    private var selectedPoint: RRDPoint? {
        guard let selectedDate else { return nil }
        return points.min { abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate)) }
    }

    /// Angezeigter Punkt: Auswahl oder der letzte mit Werten.
    private var displayPoint: RRDPoint? {
        selectedPoint ?? points.last { point in spec.series.contains { $0.value(point) != nil } }
    }

    private var hasData: Bool { !samples.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if hasData {
                chart
                    .frame(height: 170)
            } else {
                Text("Keine Daten").font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            }
        }
        .padding(.vertical, 6)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(spec.title, systemImage: spec.symbol).font(.headline)
                Spacer()
                if let date = selectedPoint?.date {
                    Text(date, format: timeframe == .hour || timeframe == .day
                         ? .dateTime.hour().minute()
                         : .dateTime.day().month().hour().minute())
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            // Legende mit Werten – Identität nie nur über Farbe.
            HStack(spacing: 14) {
                ForEach(spec.series, id: \.name) { s in
                    HStack(spacing: 5) {
                        Capsule().fill(s.color).frame(width: 12, height: 3)
                        Text(s.name).font(.caption).foregroundStyle(.secondary)
                        Text(displayPoint.flatMap { s.value($0) }.map(spec.unit.format) ?? "–")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.primary)
                    }
                }
                if let reference, let name = spec.referenceName {
                    HStack(spacing: 5) {
                        Rectangle().fill(Color.secondary).frame(width: 12, height: 1)
                        Text(name).font(.caption).foregroundStyle(.secondary)
                        Text(spec.unit.format(reference)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
    }

    private var chart: some View {
        Chart {
            ForEach(samples) { sample in
                if spec.series.count == 1 {
                    AreaMark(x: .value("Zeit", sample.date), y: .value(spec.title, sample.value))
                        .foregroundStyle(LinearGradient(colors: [spec.series[0].color.opacity(0.25), spec.series[0].color.opacity(0.02)],
                                                        startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                }
                LineMark(x: .value("Zeit", sample.date), y: .value(spec.title, sample.value))
                    .foregroundStyle(by: .value("Reihe", sample.series))
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
            if let reference {
                RuleMark(y: .value(spec.referenceName ?? "", reference))
                    .foregroundStyle(Color.secondary.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            if let point = selectedPoint {
                RuleMark(x: .value("Zeit", point.date))
                    .foregroundStyle(Color.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                ForEach(spec.series, id: \.name) { s in
                    if let v = s.value(point) {
                        PointMark(x: .value("Zeit", point.date), y: .value(spec.title, v))
                            .symbolSize(60)
                            .foregroundStyle(s.color)
                    }
                }
            }
        }
        .chartForegroundStyleScale(domain: spec.series.map(\.name), range: spec.series.map(\.color))
        .chartLegend(.hidden)
        .chartYScale(domain: 0...yUpperBound)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.secondary.opacity(0.25))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(spec.unit.format(v)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.secondary.opacity(0.15))
                AxisValueLabel(format: xFormat).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .chartXSelection(value: $selectedDate)
        .accessibilityLabel("\(spec.title), Verlauf über \(timeframe.title)")
    }

    private var yUpperBound: Double {
        let maxSample = samples.map(\.value).max() ?? 0
        var upper = max(maxSample, reference ?? 0)
        if let yMax = spec.yMax { upper = max(min(yMax, maxSample * 1.15), 0.05) }
        if upper <= 0 { upper = 1 }
        return upper * (spec.yMax == nil ? 1.08 : 1)
    }

    private var xFormat: Date.FormatStyle {
        switch timeframe {
        case .hour, .day: .dateTime.hour().minute()
        case .week: .dateTime.weekday(.abbreviated)
        case .month: .dateTime.day().month(.abbreviated)
        case .year: .dateTime.month(.abbreviated)
        }
    }
}

/// Kleines Vorschau-Diagramm (CPU der letzten Stunde) für Übersichten.
struct MetricSparkline: View {
    let client: PVEClient
    let scope: MetricsScope

    @State private var points: [RRDPoint] = []

    var body: some View {
        Chart(points.filter { $0["cpu"] != nil }) { point in
            AreaMark(x: .value("Zeit", point.date), y: .value("CPU", point["cpu"] ?? 0))
                .foregroundStyle(LinearGradient(colors: [ChartPalette.series1.opacity(0.3), ChartPalette.series1.opacity(0.02)],
                                                startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.monotone)
            LineMark(x: .value("Zeit", point.date), y: .value("CPU", point["cpu"] ?? 0))
                .foregroundStyle(ChartPalette.series1)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .interpolationMethod(.monotone)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: 0...max(0.05, (points.compactMap { $0["cpu"] }.max() ?? 0) * 1.15))
        .frame(height: 44)
        .accessibilityLabel("CPU-Auslastung der letzten Stunde")
        .task {
            points = (try? await client.rrdData(scope, timeframe: .hour, maximum: false)) ?? []
        }
    }
}
