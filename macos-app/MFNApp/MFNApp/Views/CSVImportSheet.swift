import MFNCore
import SwiftUI

/// Preview before importing a CSV file: target account, detected format, column mapping, first
/// rows and how many are new. Nothing is written before "… importieren".
struct CSVImportSheet: View {
    @Bindable var session: CSVImportSession
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var showsMapping = false

    private var document: CSVDocument { session.document }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Umsätze aus CSV importieren").font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text(session.fileName).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Form {
                Picker("Konto", selection: $session.accountID) {
                    ForEach(session.accounts) { account in
                        Text(model.csvImportLabel(for: account)).tag(Optional(account.id))
                    }
                }
                LabeledContent("Format") {
                    Text(formatText).foregroundStyle(document.preset == nil ? .secondary : .primary)
                }
                LabeledContent("Datei") {
                    Text(fileText).foregroundStyle(.secondary)
                }
                Picker("Trennzeichen", selection: Binding(get: { document.table.delimiter }, set: { session.setDelimiter($0) })) {
                    ForEach(CSVDelimiter.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Picker("Beträge", selection: Binding(get: { document.decimalSeparator }, set: { session.setDecimalSeparator($0) })) {
                    ForEach(CSVDecimalSeparator.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                if document.accountValues.count > 1 {
                    Picker("Zeilen von Konto", selection: Binding(get: { document.accountFilter }, set: { session.setAccountFilter($0) })) {
                        ForEach(document.accountValues, id: \.self) { Text($0).tag(Optional($0)) }
                        Text("Alle Zeilen").tag(String?.none)
                    }
                }
            }
            .formStyle(.columns)
            .frame(maxWidth: .infinity, alignment: .leading)

            DisclosureGroup(isExpanded: $showsMapping) {
                mappingGrid.padding(.top, 6)
            } label: {
                Text(document.mapping.isComplete ? "Spaltenzuordnung" : "Spaltenzuordnung (Datum und Betrag zuordnen)")
            }

            preview
                .frame(minHeight: 200, maxHeight: .infinity)

            summary

            if let error = session.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).font(.callout)
            }
            HStack {
                if session.isImporting {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("Import läuft")
                } else if session.isRefreshing {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("Vorschau wird berechnet")
                    Text("Vorschau wird berechnet …").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(importTitle) { runImport() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(session.importCount == 0 || session.isImporting || session.isRefreshing || session.account == nil)
            }
        }
        .padding(20)
        .frame(minWidth: 720, idealWidth: 780, minHeight: 560, idealHeight: 640)
        .onAppear { showsMapping = !document.mapping.isComplete }
        .onDisappear { session.cancel() }
        // The error line alone is silent for VoiceOver.
        .onChange(of: session.error) { _, error in
            if let error { AccessibilityNotification.Announcement(error).post() }
        }
    }

    // MARK: Parts

    private var formatText: String {
        if let preset = document.preset { return preset.displayName }
        if document.headerRow == nil { return String(localized: "Unbekannt, ohne Kopfzeile: Spalten bitte zuordnen") }
        return String(localized: "Allgemein (Spalten nach Kopfzeile erkannt)")
    }

    private var fileText: String {
        var parts = [document.table.encoding.displayName]
        if let header = document.headerRow {
            parts.append(String(localized: "Kopfzeile in Zeile \(String(document.table.lines[header]))"))
        }
        parts.append(String(localized: "\(document.dataRows.count) Datenzeilen"))
        return parts.joined(separator: " · ")
    }

    private var importTitle: String {
        switch session.importCount {
        case 0: String(localized: "Importieren")
        case 1: String(localized: "1 Umsatz importieren")
        default: String(localized: "\(session.importCount) Umsätze importieren")
        }
    }

    private var mappingGrid: some View {
        let names = document.columnNames
        let samples = document.dataRows.first ?? []
        return Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            ForEach(Array(CSVField.mappable.chunked(2).enumerated()), id: \.offset) { _, pair in
                GridRow {
                    ForEach(pair, id: \.self) { field in
                        Picker(field.title, selection: Binding(get: { document.mapping[field] }, set: { session.setColumn($0, for: field) })) {
                            Text("Keine").tag(Int?.none)
                            ForEach(names.indices, id: \.self) { index in
                                Text(columnLabel(names[index], sample: index < samples.count ? samples[index] : "")).tag(Optional(index))
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    /// Header plus the first value (format hint), unless amounts are hidden.
    private func columnLabel(_ name: String, sample: String) -> String {
        guard !sample.isEmpty, !model.hideAmounts else { return name }
        let short = sample.count > 24 ? String(sample.prefix(24)) + "…" : sample
        return String(localized: "\(name) (z. B. \(short))")
    }

    @ViewBuilder
    private var preview: some View {
        let rows = session.previewRows
        if rows.isEmpty {
            ContentUnavailableView(
                document.mapping.isComplete ? "Keine Umsätze gefunden" : "Spalten zuordnen",
                systemImage: "tablecells",
                description: Text(document.mapping.isComplete
                                  ? "Die Datei enthält keine lesbaren gebuchten Umsätze."
                                  : "Ordne mindestens Buchungstag und Betrag (oder Soll und Haben) zu.")
            )
        } else {
            Table(rows) {
                TableColumn("Datum") { row in
                    Text(row.transaction.effectiveDate.startDate.formatted(Self.dateStyle)).monospacedDigit()
                }
                .width(min: 70, ideal: 80, max: 90)
                // Truncated cells: the full text as tooltip.
                TableColumn("Gegenpartei") { row in
                    Text(row.transaction.counterpartName).lineLimit(1).help(row.transaction.counterpartName)
                }
                TableColumn("Verwendungszweck") { row in
                    Text(row.transaction.purpose).lineLimit(1).foregroundStyle(.secondary).help(row.transaction.purpose)
                }
                TableColumn("Betrag") { row in
                    AmountText(cents: row.transaction.amountCents, currency: row.transaction.currency, signed: true)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 80, ideal: 100, max: 130)
                TableColumn("Status") { row in
                    // State in text and symbol, never colour alone.
                    Label(row.state.title, systemImage: row.state == .new ? "plus.circle" : "equal.circle")
                        .foregroundStyle(row.state == .new ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                }
                .width(min: 90, ideal: 120, max: 140)
            }
            .accessibilityLabel("Vorschau der ersten \(rows.count) Zeilen")
        }
    }

    private var summary: some View {
        let plan = session.plan
        let skipped = session.result.skipped
        let problems = session.problems
        let filtered = skipped.count - problems.count
        var parts = [String(localized: "\(plan.new.count) neu"), String(localized: "\(plan.duplicates.count) bereits vorhanden")]
        if !plan.likelyDuplicates.isEmpty { parts.append(String(localized: "\(plan.likelyDuplicates.count) wahrscheinlich vorhanden")) }
        if filtered > 0 { parts.append(String(localized: "\(filtered) nicht gebucht oder anderes Konto")) }
        if !problems.isEmpty { parts.append(String(localized: "\(problems.count) nicht lesbar")) }
        return VStack(alignment: .leading, spacing: 6) {
            Text(parts.joined(separator: " · ")).monospacedDigit()
            if !plan.likelyDuplicates.isEmpty {
                Toggle("Wahrscheinlich vorhandene trotzdem importieren", isOn: $session.includeLikelyDuplicates)
                    .help("Gleicher Tag, Betrag und Händler wie ein gespeicherter Umsatz, aber anderer Verwendungszweck.")
            }
            if !problems.isEmpty {
                let shown = problems.prefix(4).map { String(localized: "Zeile \(String($0.line)): \($0.reason.title)") }.joined(separator: ", ")
                let message = problems.count > 4
                    ? String(localized: "\(shown) und \(problems.count - 4) weitere. Diese Zeilen werden übersprungen.")
                    : String(localized: "\(shown). Diese Zeilen werden übersprungen.")
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            Text("Importierte Umsätze gelten als gebucht und werden danach wie abgeglichene kategorisiert. Ein späterer Abgleich verdoppelt sie nicht, wenn die Bank denselben Verwendungszweck liefert.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
    }

    private static let dateStyle = Date.FormatStyle(locale: Locale.autoupdatingCurrent, timeZone: BankDay.bankTimeZone)
        .day(.twoDigits).month(.twoDigits).year()

    private func runImport() {
        guard !session.isImporting else { return }
        session.isImporting = true
        session.error = nil
        Task {
            let outcome = await model.importCSV(session)
            session.isImporting = false
            switch outcome {
            case let .failure(message):
                session.error = message
            case let .success(count, account):
                AccessibilityNotification.Announcement(count == 1 ? String(localized: "1 Umsatz importiert") : String(localized: "\(count) Umsätze importiert")).post()
                // Locked meanwhile: `close()` dropped the sheet and the selection stays empty.
                if !model.lock.isLocked { model.selection = .account(account) }
                dismiss()
            }
        }
    }
}

private extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
