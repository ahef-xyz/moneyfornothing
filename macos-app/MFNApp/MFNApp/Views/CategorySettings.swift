import MFNCore
import SwiftUI

/// Settings → Kategorien: the user's rules (list, edit, delete) and the state of the automatic
/// categorization.
struct CategorySettings: View {
    @Environment(AppModel.self) private var model
    @State private var editing: RuleDraft?
    @State private var error: String?
    @Environment(\.openWindow) private var openWindow
    @AppStorage(Preferences.useCategoryModel) private var useModel = true

    var body: some View {
        Form {
            Section {
                if model.lock.isLocked {
                    Text("MFN entsperren, um die Regeln zu sehen.")
                        .foregroundStyle(.secondary)
                } else if model.categoryRules.isEmpty {
                    Text("Noch keine Regeln. Wähle einen Umsatz und dann „Regel erstellen …“ (⇧⌘K).")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.categoryRules) { rule in
                        RuleRow(rule: rule, editing: $editing, error: $error)
                    }
                }
            } header: {
                Text("Regeln")
            } footer: {
                Text("Regeln gehen allen Vorschlägen vor: genaue Merkmale (Gläubiger-ID, Mandat, IBAN) vor Text, bei Gleichstand die neueste. Manuell gesetzte Kategorien ändert keine Regel.")
                    .foregroundStyle(.secondary)
            }
            if let error {
                Text(error).foregroundStyle(.red)
            }
            if !model.lock.isLocked {
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Kategorien einrichten")
                            Text("Mit wenigen Entscheidungen zu Gehalt, Verträgen und häufigen Händlern die meisten Umsätze kategorisieren.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Assistent öffnen …") {
                            openWindow(id: MainWindow.id)
                            model.showCategorySetup()
                        }
                        .disabled(!model.canShowCategorySetup)
                    }
                }
                Section {
                    LabeledContent("Ohne Kategorie") { Text("\(model.uncategorizedCount)").monospacedDigit() }
                    LabeledContent("Zu prüfen") { Text("\(model.reviewCount)").monospacedDigit() }
                    HStack {
                        Button("Jetzt kategorisieren") { model.categorizeInBackground() }
                            .disabled(!model.canCategorize || model.isCategorizing)
                        if model.isCategorizing {
                            ProgressView().controlSize(.small)
                                .accessibilityLabel("Kategorisierung läuft")
                            if let status = model.categorizationStatus {
                                Text(status).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Automatik")
                }
            }
            Section {
                Toggle(isOn: $useModel) {
                    Text("Apple Intelligence für Kategorien verwenden")
                    Text("Ordnet ein, was Regeln und ähnliche Umsätze offenlassen. Auf älteren oder kleinen Macs kann das lange dauern. Aus: Diese Umsätze behalten nur einen unsicheren Vorschlag (dann unter „Zu prüfen“) oder bleiben ohne Kategorie, für den Assistenten oder ⌘K.")
                }
                .onChange(of: useModel) { _, on in model.categoryModelSwitched(on: on) }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { draft in
            RuleEditorSheet(draft: draft) { editing = nil }
                .environment(model)
        }
    }
}

private struct RuleRow: View {
    let rule: CategoryRule
    @Binding var editing: RuleDraft?
    @Binding var error: String?
    @Environment(AppModel.self) private var model

    var body: some View {
        let count = model.ruleMatches(rule).all.count
        HStack(spacing: 10) {
            Image(systemName: rule.categoryID.symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.categoryID.title)
                Text(rule.match.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text(count == 1 ? "1 Umsatz" : "\(count) Umsätze")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button("Bearbeiten", systemImage: "pencil") { editing = RuleDraft(rule: rule) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Regel bearbeiten")
            Button("Löschen", systemImage: "trash") { remove() }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Regel löschen (bereits zugeordnete Kategorien bleiben)")
        }
        .contextMenu {
            Button("Bearbeiten …") { editing = RuleDraft(rule: rule) }
            Button("Löschen", role: .destructive) { remove() }
        }
    }

    private func remove() {
        Task { error = await model.removeRule(rule.id) }
    }
}
