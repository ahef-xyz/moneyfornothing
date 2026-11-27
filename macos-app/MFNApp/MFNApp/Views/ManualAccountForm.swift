import MFNCore
import SwiftUI

/// "Konto ohne Anbindung" form inside the bank assistant (protocol v10, `ConnectorID.manual`):
/// name, type, currency, optional IBAN and opening balance.
struct ManualAccountForm: View {
    @Bindable var setup: BankSetup

    private var ibanProblem: String? {
        guard let iban = ManualAccount.normalizedIBAN(setup.manual.iban) else { return nil }
        return ManualAccount.validate(iban: iban)?.message
    }

    private var openingProblem: Bool {
        let text = setup.manual.openingAmount.trimmingCharacters(in: .whitespaces)
        return !text.isEmpty && CSVValues.cents(text) == nil
    }

    var body: some View {
        Form {
            Section {
                if setup.manualEditing == nil {
                    TextField("Name in MFN", text: $setup.manual.name, prompt: Text("z. B. Sparkasse Giro"))
                }
                Picker("Kontoart", selection: $setup.manual.type) {
                    ForEach(ManualAccountDraft.types, id: \.self) { type in
                        Text(ManualAccountDraft.title(type)).tag(type)
                    }
                }
                Picker("Währung", selection: $setup.manual.currency) {
                    ForEach(setup.manual.currencies, id: \.self) { code in
                        Text(code).tag(code)
                    }
                }
                .disabled(setup.manualCurrencyLocked)
                .accessibilityHint(setup.manualCurrencyLocked ? Self.currencyLockedText : "")
                TextField("IBAN (optional)", text: $setup.manual.iban, prompt: Text("DE00 0000 0000 0000 0000 00"))
                    .monospacedDigit()
                    .accessibilityHint(ibanProblem ?? String(localized: "Optional, wird nur angezeigt und nie übertragen."))
                if let ibanProblem {
                    Label(ibanProblem, systemImage: "exclamationmark.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                if setup.manualEditing == nil {
                    Text("So erscheint das Konto in der Seitenleiste. Umbenennen geht später im Kontextmenü.")
                } else if setup.manualCurrencyLocked {
                    Text(Self.currencyLockedText)
                }
            }
            Section {
                TextField("Startsaldo (optional)", text: $setup.manual.openingAmount, prompt: Text("0,00"))
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .accessibilityHint(openingProblem ? String(localized: "Kein gültiger Betrag") : String(localized: "Betrag in \(setup.manual.currency), negativ mit Minus"))
                Toggle("Startsaldo gilt vor einem Datum", isOn: $setup.manual.usesOpeningDate)
                    .disabled(setup.manual.openingAmount.trimmingCharacters(in: .whitespaces).isEmpty)
                if setup.manual.usesOpeningDate {
                    DatePicker("Umsätze zählen ab", selection: $setup.manual.openingDate, displayedComponents: .date)
                }
            } header: {
                Text("Kontostand")
            } footer: {
                Text(setup.manual.usesOpeningDate
                     ? "Kontostand = Startsaldo + gebuchte Umsätze ab diesem Tag. Ältere importierte Umsätze sind im Startsaldo schon enthalten."
                     : "Kontostand = Startsaldo + alle gebuchten Umsätze. Ohne Startsaldo zählen nur die importierten Umsätze.")
            }
            if let error = setup.finishError {
                Section {
                    Label(error, systemImage: "xmark.octagon")
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .onSubmit { Task { await setup.saveManualAccount() } }
        // Errors and the IBAN problem are announced, not only shown (the hint is read on focus only).
        .onChange(of: setup.finishError) { _, error in
            if let error { AccessibilityNotification.Announcement(error).post() }
        }
        .task(id: ibanProblem) {
            // After typing pauses, so VoiceOver does not speak on every keystroke.
            guard let ibanProblem else { return }
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            AccessibilityNotification.Announcement(ibanProblem).post()
        }
    }

    static var currencyLockedText: String { String(localized: "Die Währung lässt sich nicht ändern, solange das Konto Umsätze hat: ihre Beträge sind in dieser Währung gespeichert.") }
}
