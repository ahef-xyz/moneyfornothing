import Charts
import MFNCore
import SwiftUI

/// Depot value over time (solid) against the purchase value (dashed), from the points MFN records
/// with every depot sync (`LedgerSnapshot.depotHistory`); banks deliver no history. Neutral
/// colours (gain is told by the gap, not by green/red), hidden with the amounts (⇧⌘H). Hover
/// shows the exact values of a day.
struct DepotHistoryChart: View {
    let account: Account
    @Environment(AppModel.self) private var model
    @State private var range: Range = .all

    enum Range: String, CaseIterable, Identifiable {
        case month = "1M", halfYear = "6M", year = "1J", all = "Max"
        var id: Self { self }

        var months: Int? {
            switch self {
            case .month: 1
            case .halfYear: 6
            case .year: 12
            case .all: nil
            }
        }

        var title: String {
            switch self {
            case .month: String(localized: "1 Monat")
            case .halfYear: String(localized: "6 Monate")
            case .year: String(localized: "1 Jahr")
            case .all: String(localized: "Gesamter Verlauf")
            }
        }

        /// Short label of the segment.
        var label: String {
            switch self {
            case .month: String(localized: "1M")
            case .halfYear: String(localized: "6M")
            case .year: String(localized: "1J")
            case .all: String(localized: "Max")
            }
        }
    }

    private var allPoints: [DepotValuePoint] { model.snapshot.depotHistory[account.id] ?? [] }

    private func points(in all: [DepotValuePoint]) -> [DepotValuePoint] {
        guard let months = range.months, let last = all.last else { return all }
        let start = last.day.adding(months: -months)
        return all.filter { $0.day >= start }
    }

    var body: some View {
        let all = allPoints
        let points = points(in: all)
        VStack(alignment: .leading, spacing: 6) {
            if all.count < 2 {
                Label(all.isEmpty
                      ? String(localized: "Der Verlauf wird ab dem nächsten Abgleich aufgezeichnet, die Bank liefert keinen.")
                      : String(localized: "Verlauf seit \(DayFormat.short(all[0].day)). Ab dem zweiten Tag mit Abgleich erscheint hier ein Diagramm."),
                      systemImage: "chart.xyaxis.line")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.hideAmounts {
                Label("Depotverlauf ausgeblendet, wie die Beträge", systemImage: "eye.slash")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                // Legend and picker side by side, stacked when large text does not fit.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        legend(points)
                        Spacer()
                        picker
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        legend(points)
                        picker
                    }
                }
                HistoryPlot(points: points, summary: Self.summary(points), title: range.title)
                Text(Self.summary(points))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true)   // the chart element reads the same
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private var picker: some View {
        Picker("Zeitraum", selection: $range) {
            ForEach(Range.allCases) { Text($0.label).tag($0).help($0.title).accessibilityLabel($0.title) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Zeitraum des Verlaufs")
    }

    private func legend(_ points: [DepotValuePoint]) -> some View {
        HStack(spacing: 10) {
            LegendLine(dashed: false, text: "Depotwert")
            if points.contains(where: { $0.purchaseCents != nil }) { LegendLine(dashed: true, text: "Einstandswert") }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }

    /// One line: first day, last day, change, purchase value (also the VoiceOver value).
    static func summary(_ points: [DepotValuePoint]) -> String {
        guard let first = points.first, let last = points.last else { return "" }
        let currency = last.currency
        var parts = ["\(DayFormat.short(first.day)): \(Money.format(first.valueCents, currency: currency))",
                     "\(DayFormat.short(last.day)): \(Money.format(last.valueCents, currency: currency))",
                     String(localized: "Veränderung \(Money.format(last.valueCents - first.valueCents, currency: currency, signed: true))")]
        if let purchase = last.purchaseCents {
            parts.append(String(localized: "Einstandswert \(Money.format(purchase, currency: currency))"))
        }
        return parts.joined(separator: " · ")
    }

    /// The chart with its hover state, so moving the pointer does not recompute the data above.
    private struct HistoryPlot: View {
        let points: [DepotValuePoint]
        let summary: String
        let title: String
        @State private var hovered: Date?

        /// Purchase values in unbroken runs: a day without one breaks the dashed line.
        private var purchaseRuns: [(run: Int, point: DepotValuePoint, cents: Int)] {
            var run = 0
            var previousHad = false
            var result: [(Int, DepotValuePoint, Int)] = []
            for point in points {
                if let cents = point.purchaseCents {
                    if !previousHad { run += 1 }
                    result.append((run, point, cents))
                    previousHad = true
                } else {
                    previousHad = false
                }
            }
            return result
        }

        var body: some View {
            let selected = hovered.flatMap { date in points.min { abs($0.day.startDate.timeIntervalSince(date)) < abs($1.day.startDate.timeIntervalSince(date)) } }
            let currency = points.last?.currency ?? "EUR"
            Chart {
                ForEach(points) { point in
                    LineMark(x: .value("Tag", point.day.startDate), y: .value("Wert", Double(point.valueCents) / 100),
                             series: .value("Reihe", "Depotwert"))
                        .foregroundStyle(Color.primary.opacity(0.8))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
                ForEach(purchaseRuns, id: \.point.day) { entry in
                    LineMark(x: .value("Tag", entry.point.day.startDate), y: .value("Wert", Double(entry.cents) / 100),
                             series: .value("Reihe", "Einstandswert \(entry.run)"))
                        .interpolationMethod(.stepEnd)
                        .foregroundStyle(Color.primary.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                }
                if let selected {
                    RuleMark(x: .value("Tag", selected.day.startDate))
                        .foregroundStyle(Color.secondary.opacity(0.4))
                        .lineStyle(StrokeStyle(lineWidth: 0.5))
                        .annotation(position: .top, spacing: 2, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            Tooltip(point: selected)
                        }
                    PointMark(x: .value("Tag", selected.day.startDate), y: .value("Wert", Double(selected.valueCents) / 100))
                        .symbolSize(30)
                        .foregroundStyle(Color.primary)
                }
            }
            .chartLegend(.hidden)
            .chartYScale(domain: .automatic(includesZero: false))
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.2))
                    AxisValueLabel {
                        if let euros = value.as(Double.self) {
                            Text(Money.format(Int((euros * 100).rounded()), currency: currency)).monospacedDigit()
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated).locale(Locale.autoupdatingCurrent))
                }
            }
            .chartXSelection(value: $hovered)
            .frame(minHeight: 140, idealHeight: 140, maxHeight: 220)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Depotverlauf, \(title)")
            .accessibilityValue(summary)
            .accessibilityChartDescriptor(DepotChartDescriptor(points: points, summary: summary))
        }
    }

    private struct Tooltip: View {
        let point: DepotValuePoint

        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                Text(DayFormat.short(point.day)).font(.caption.weight(.semibold))
                row("Depotwert", point.valueCents)
                if let purchase = point.purchaseCents {
                    row("Einstandswert", purchase)
                    row("Gewinn/Verlust", point.valueCents - purchase, signed: true)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }

        private func row(_ label: LocalizedStringKey, _ cents: Int, signed: Bool = false) -> some View {
            HStack(spacing: 8) {
                Text(label)
                Spacer(minLength: 4)
                Text(Money.format(cents, currency: point.currency, signed: signed)).monospacedDigit()
            }
            .font(.caption)
        }
    }

    private struct LegendLine: View {
        let dashed: Bool
        let text: LocalizedStringKey

        var body: some View {
            HStack(spacing: 4) {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: 1))
                    path.addLine(to: CGPoint(x: 12, y: 1))
                }
                .stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: dashed ? [3, 3] : []))
                .frame(width: 12, height: 2)
                Text(text)
            }
        }
    }
}

/// Audio graph and data table for VoiceOver (Rotor → "Diagramm").
private struct DepotChartDescriptor: AXChartDescriptorRepresentable {
    let points: [DepotValuePoint]
    let summary: String

    func makeChartDescriptor() -> AXChartDescriptor {
        let currency = points.last?.currency ?? "EUR"
        let labels = points.map { DayFormat.short($0.day) }
        let values = points.flatMap { [$0.valueCents] + ($0.purchaseCents.map { [$0] } ?? []) }.map { Double($0) / 100 }
        let low = values.min() ?? 0, high = values.max() ?? 0
        let xAxis = AXCategoricalDataAxisDescriptor(title: String(localized: "Tag"), categoryOrder: labels)
        let yAxis = AXNumericDataAxisDescriptor(title: String(localized: "Wert"), range: low...max(high, low + 1), gridlinePositions: []) {
            Money.format(Int(($0 * 100).rounded()), currency: currency)
        }
        let value = AXDataSeriesDescriptor(name: String(localized: "Depotwert"), isContinuous: true, dataPoints: zip(labels, points).map {
            AXDataPoint(x: $0.0, y: Double($0.1.valueCents) / 100)
        })
        let purchase = AXDataSeriesDescriptor(name: String(localized: "Einstandswert"), isContinuous: true, dataPoints: zip(labels, points).compactMap { label, point in
            point.purchaseCents.map { AXDataPoint(x: label, y: Double($0) / 100) }
        })
        return AXChartDescriptor(title: String(localized: "Depotverlauf"), summary: summary, xAxis: xAxis, yAxis: yAxis, additionalAxes: [],
                                 series: purchase.dataPoints.isEmpty ? [value] : [value, purchase])
    }
}
