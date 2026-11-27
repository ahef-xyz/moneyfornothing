import MFNCore
import SwiftUI

/// Which two connections the report compares.
struct MergeRequest: Identifiable, Hashable {
    let source: Connection
    let target: Connection

    var id: String { "\(source.id.rawValue)>\(target.id.rawValue)" }
}

/// "Zusammenführen prüfen …" (developer mode): what merging the web connection into the FinTS
/// connection would do (`ConnectionMerge.plan`, computed off the main actor whenever the ledger
/// changes), then the merge itself after a confirmation that defaults to "Abbrechen".
struct MergeReportSheet: View {
    let request: MergeRequest
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var plan: Result<ConnectionMerge.Plan, ConnectionMerge.PlanError>?
    @State private var confirming = false
    @State private var running = false
    @State private var error: String?
    /// Set after a successful merge: the backup taken before (offered for deletion).
    @State private var backup: URL?

    /// Longest list shown per kind; more would only slow the sheet down.
    static let listLimit = 200

    private var loadedPlan: ConnectionMerge.Plan? { try? plan?.get() }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Zusammenführen prüfen").font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text("„\(request.source.displayName)“ (Web-Banking) zu „\(request.target.displayName)“ (FinTS). Bis „Zusammenführen“ bestätigt ist, ändert sich nichts.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let backup {
                done(backup)
            } else {
                switch plan {
                case let .success(plan)?:
                    report(plan)
                case let .failure(error)?:
                    ErrorText(message: Self.message(error))
                case nil:
                    ProgressView("Wird berechnet …")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            if let error {
                ErrorText(message: error)
            }
            buttons
        }
        .padding(20)
        .frame(minWidth: 520, idealWidth: 580, minHeight: 480, idealHeight: 640)
        .task(id: model.snapshotRevision) {
            // Recomputed when the ledger changes (a sync of either bank), never during the merge.
            guard !running, backup == nil else { return }
            let snapshot = model.ledger  // the full ledger: hidden accounts merge too
            let source = request.source.id
            let target = request.target.id
            plan = await Task.detached(priority: .userInitiated) {
                Result { () throws(ConnectionMerge.PlanError) in try ConnectionMerge.plan(snapshot, source: source, target: target) }
            }.value
        }
        .confirmationDialog(confirmationTitle, isPresented: $confirming) {
            Button("Zusammenführen", role: .destructive, action: merge)
            Button("Abbrechen", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text("Ältere Umsätze, Kategorien, Kontonamen und Budgets gehen an die FinTS-Verbindung, danach wird die Web-Verbindung mit Zugangsdaten und Sitzung entfernt. Vorher legt MFN eine verschlüsselte Kopie der Datenbank neben ihr ab; in der App lässt sich das nicht rückgängig machen.")
        }
    }

    @ViewBuilder
    private var buttons: some View {
        HStack {
            if running {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Zusammenführen läuft")
            }
            Spacer()
            if let backup {
                Button("Sicherung löschen", role: .destructive) { deleteBackup(backup) }
                Button("Fertig") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            } else {
                // Return closes; the irreversible action never sits on a default key.
                Button("Schließen", role: .cancel) { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(running)
                Button("Zusammenführen …") { confirming = true }
                    .disabled(running || (loadedPlan?.isEmpty ?? true))
            }
        }
    }

    /// The warning is in the title, so it cannot be overlooked in the message.
    private var confirmationTitle: String {
        let suspicious = loadedPlan?.suspicious ?? 0
        let base = String(localized: "„\(request.source.displayName)“ in „\(request.target.displayName)“ übernehmen?")
        return suspicious == 0 ? base : String(localized: "\(base) \(suspicious) Umsätze gibt es nur im Web, obwohl sie im FinTS-Zeitraum liegen.")
    }

    private func done(_ backup: URL) -> some View {
        Form {
            Section {
                Label("Zusammengeführt. Die Web-Verbindung ist entfernt.", systemImage: "checkmark.circle")
                LabeledContent("Sicherung vorher", value: backup.lastPathComponent)
                Text("Liegt verschlüsselt neben der Datenbank und enthält noch alle Daten der Web-Verbindung. Löschen, wenn alles stimmt.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func report(_ plan: ConnectionMerge.Plan) -> some View {
        Form {
            ForEach(plan.accounts, id: \.pair.target.id) { account in
                Section {
                    if let newName = account.newName {
                        LabeledContent("Neuer Kontoname", value: newName)
                    }
                    LabeledContent("FinTS-Zeitraum ab") {
                        Text(account.windowStart.map { $0.startDate.formatted(date: .abbreviated, time: .omitted) } ?? String(localized: "noch keine Umsätze"))
                    }
                    CountRow(label: "Doppelt, werden zusammengeführt", value: account.matched.count)
                    CountRow(label: "davon nur über Betrag und Tag erkannt", value: account.weakMatches)
                    CountRow(label: "Ältere Umsätze aus dem Web, werden übernommen", value: account.history.count)
                    CountRow(label: "Nur im Web, obwohl im FinTS-Zeitraum, werden übernommen", value: account.sourceOnlyInWindow.count, attention: !account.sourceOnlyInWindow.isEmpty)
                    CountRow(label: "Kategorien, werden übernommen", value: account.categoriesToCarry)
                    CountRow(label: "Nur über FinTS (neu)", value: account.targetOnly.count)
                    CountRow(label: "Vorgemerkt oder geplant ohne Gegenstück, entfallen", value: account.dropped.count)
                    if !account.sourceOnlyInWindow.isEmpty {
                        DisclosureGroup("Nur im Web anzeigen") {
                            ForEach(account.sourceOnlyInWindow.prefix(Self.listLimit)) { TransactionLine(transaction: $0) }
                            more(account.sourceOnlyInWindow.count)
                        }
                    }
                    if account.weakMatches > 0 {
                        let weak = account.matched.filter(\.weak)
                        DisclosureGroup("Unsichere Paare anzeigen") {
                            ForEach(weak.prefix(Self.listLimit), id: \.target.id) { pair in
                                VStack(alignment: .leading, spacing: 2) {
                                    TransactionLine(transaction: pair.source, prefix: "Web")
                                    TransactionLine(transaction: pair.target, prefix: "FinTS")
                                }
                                .accessibilityElement(children: .contain)
                                .accessibilityLabel("Unsicheres Paar")
                            }
                            more(weak.count)
                        }
                    }
                } header: {
                    Text("\(model.displayName(of: account.pair.source)) zu \(model.displayName(of: account.pair.target))")
                        .accessibilityAddTraits(.isHeader)
                } footer: {
                    Text(account.pair.reason == .iban ? "Zugeordnet über die IBAN" : "Zugeordnet als einziges Konto dieser Art")
                }
            }
            if !plan.unmatchedSourceAccounts.isEmpty || !plan.unmatchedTargetAccounts.isEmpty {
                Section("Ohne Gegenstück") {
                    ForEach(plan.unmatchedSourceAccounts) { account in
                        LabeledContent(model.displayName(of: account)) { Text("nur im Web") }
                    }
                    ForEach(plan.unmatchedTargetAccounts) { account in
                        LabeledContent(model.displayName(of: account)) { Text("nur über FinTS") }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func more(_ total: Int) -> some View {
        if total > Self.listLimit {
            Text("… und \(total - Self.listLimit) weitere").foregroundStyle(.secondary)
        }
    }

    private func merge() {
        running = true
        error = nil
        AccessibilityNotification.Announcement(String(localized: "Zusammenführen läuft")).post()
        Task {
            let outcome = await model.mergeConnection(request.source, into: request.target)
            running = false
            switch outcome {
            case let .merged(url):
                backup = url
                AccessibilityNotification.Announcement(String(localized: "Zusammengeführt")).post()
            case let .failed(message):
                error = message
                AccessibilityNotification.Announcement(String(localized: "Fehler: \(message)")).post()
            }
        }
    }

    private func deleteBackup(_ url: URL) {
        if let failure = model.deleteBackup(url) {
            error = failure
            AccessibilityNotification.Announcement(String(localized: "Fehler: \(failure)")).post()
        } else {
            AccessibilityNotification.Announcement(String(localized: "Sicherung gelöscht")).post()
            dismiss()
        }
    }

    static func message(_ error: ConnectionMerge.PlanError) -> String {
        switch error {
        case .unknownConnection: String(localized: "Eine der beiden Banken gibt es nicht mehr.")
        case .sameConnection: String(localized: "Das ist zweimal dieselbe Bank.")
        case .differentBanks: String(localized: "Die beiden Verbindungen gehören zu verschiedenen Banken.")
        }
    }
}

/// Red text plus a symbol (meaning never by colour alone), read as "Fehler: …".
private struct ErrorText: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.red)
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Fehler: \(message)")
    }
}

/// One count; `attention` adds a symbol (not colour alone) and "bitte prüfen" for VoiceOver.
private struct CountRow: View {
    let label: LocalizedStringKey
    let value: Int
    var attention = false

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 4) {
                if attention {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                }
                Text(value, format: .number).monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(attention ? String(localized: "\(value), bitte prüfen") : String(value))
    }
}

private struct TransactionLine: View {
    let transaction: MFNCore.Transaction
    var prefix: String?
    @Environment(AppModel.self) private var model

    private var name: String { transaction.counterpartName.isEmpty ? transaction.purpose : transaction.counterpartName }
    private var date: String { transaction.effectiveDate.startDate.formatted(date: .numeric, time: .omitted) }

    var body: some View {
        HStack(spacing: 8) {
            if let prefix {
                Text(prefix).foregroundStyle(.secondary).frame(minWidth: 40, alignment: .leading)
            }
            Text(date)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(name)
                .lineLimit(1)
                .help(name)
            Spacer()
            AmountText(cents: transaction.amountCents, currency: transaction.currency, signed: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([prefix, date, name, amount].compactMap(\.self).joined(separator: ", "))
    }

    private var amount: String {
        model.hideAmounts ? String(localized: "Betrag ausgeblendet") : Money.format(transaction.amountCents, currency: transaction.currency, signed: true)
    }
}
