import MFNCore
import SwiftUI

/// "Zugangsdaten ändern…" for one connection. Non-secret values are prefilled, secrets are
/// always entered anew (MFN never shows a stored password).
struct CredentialsSheet: View {
    let connection: Connection
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String] = [:]
    @State private var error: String?

    private var fields: [CredentialField] { BankAccess.of(connection).credentialFields }
    private var problem: String? {
        CredentialForm.problem(CredentialForm.cleaned(values, fields: fields).values, fields: fields)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                BankBadge(connection: connection, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Zugangsdaten für \(connection.displayName)")
                        .font(.headline)
                    Text("Gilt ab der nächsten Anmeldung.")
                        .foregroundStyle(.secondary)
                }
            }
            if fields.isEmpty {
                Text("Diese Bank meldet sich ohne gespeicherte Zugangsdaten an.")
                    .foregroundStyle(.secondary)
            } else {
                Form {
                    CredentialForm(fields: fields, values: $values)
                }
                .formStyle(.columns)
                CredentialNote()
            }
            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Speichern", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem != nil || fields.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear(perform: load)
    }

    private func load() {
        let stored = try? model.credentialStore.credentials(for: connection.id)
        values = [:]
        for field in fields where !field.isSecret {
            values[field.key] = stored?[field.key]
        }
    }

    private func save() {
        let credentials = CredentialForm.cleaned(values, fields: fields)
        guard problem == nil else { return }
        do {
            try model.updateCredentials(credentials, for: connection)
            values = [:]
            dismiss()
        } catch {
            self.error = "Speichern im Schlüsselbund fehlgeschlagen: \(error.localizedDescription)"
        }
    }
}

/// Confirmation and execution of "Bank entfernen…" and the credentials sheet, attachable to any
/// view that offers these actions (sidebar, settings).
struct BankActionsModifier: ViewModifier {
    @Binding var editing: Connection?
    @Binding var removing: Connection?
    @Environment(AppModel.self) private var model
    @State private var error: String?

    func body(content: Content) -> some View {
        content
            .sheet(item: $editing) { connection in
                CredentialsSheet(connection: connection)
            }
            .alert(
                "„\(removing?.displayName ?? "")“ entfernen?",
                isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                presenting: removing
            ) { connection in
                Button("Entfernen", role: .destructive) {
                    Task { error = await model.removeConnection(connection) }
                }
                Button("Abbrechen", role: .cancel) {}
            } message: { connection in
                let count = model.ledger.accounts(of: connection.id).count
                Text("MFN löscht \(count == 1 ? "das Konto" : "die \(count) Konten") dieser Bank mit allen Umsätzen sowie Zugangsdaten und Sitzung aus dem Schlüsselbund. Bei der Bank selbst ändert sich nichts.")
            }
            .alert("Bank entfernen", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") {}
            } message: {
                Text(error ?? "")
            }
    }
}

extension View {
    func bankActions(editing: Binding<Connection?>, removing: Binding<Connection?>) -> some View {
        modifier(BankActionsModifier(editing: editing, removing: removing))
    }
}

/// "Konten anzeigen": one checkbox per account of a bank, hidden ones included. Hidden accounts
/// keep syncing; they only leave the sidebar, the lists and the totals.
struct AccountVisibilityMenu: View {
    let connection: ConnectionID
    @Environment(AppModel.self) private var model

    var body: some View {
        let accounts = model.allAccounts(of: connection)
        if !accounts.isEmpty {
            Menu("Konten anzeigen") {
                ForEach(accounts) { account in
                    Toggle(model.displayName(of: account), isOn: Binding(
                        get: { !model.isHidden(account.id) },
                        set: { model.setHidden(!$0, account: account.id) }
                    ))
                }
                Divider()
                Button("Alle anzeigen") {
                    for account in accounts { model.setHidden(false, account: account.id) }
                }
                .disabled(accounts.allSatisfy { !model.isHidden($0.id) })
            }
        }
    }
}

/// "In Summe einrechnen": one checkbox per visible account of a bank. Unticked accounts keep their
/// balance in the sidebar but leave the bank sum and the overall total.
struct AccountTotalsMenu: View {
    let connection: ConnectionID
    @Environment(AppModel.self) private var model

    var body: some View {
        let accounts = model.orderedAccounts(of: connection)
        if !accounts.isEmpty {
            Menu("In Summe einrechnen") {
                ForEach(accounts) { account in
                    Toggle(account.name, isOn: Binding(
                        get: { model.isCountedInTotals(account.id) },
                        set: { model.setCountedInTotals($0, account: account.id) }
                    ))
                }
                Divider()
                Button("Alle einrechnen") {
                    for account in accounts { model.setCountedInTotals(true, account: account.id) }
                }
                .disabled(accounts.allSatisfy { model.isCountedInTotals($0.id) })
            }
        }
    }
}

/// What "Umbenennen …" was chosen for.
enum RenameTarget: Identifiable {
    case bank(Connection)
    case account(Account)

    var id: String {
        switch self {
        case let .bank(connection): "bank-\(connection.id.rawValue)"
        case let .account(account): "account-\(account.id.rawValue)"
        }
    }
}

/// Rename a bank (stored as its display name) or an account (the user's name over the bank's,
/// which the bank sends again on every sync).
struct RenameSheet: View {
    let target: RenameTarget
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var error: String?
    @State private var isSaving = false

    private var title: String {
        switch target {
        case .bank: "Bank umbenennen"
        case .account: "Konto umbenennen"
        }
    }

    /// For accounts: the bank's own name, if the user replaced it.
    private var bankName: String? {
        guard case let .account(account) = target else { return nil }
        return model.bankName(of: account.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
                .onSubmit(save)
            if let bankName {
                Text("Name bei der Bank: \(bankName)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
            }
            HStack {
                if let bankName, name != bankName {
                    Button("Originalnamen verwenden") { name = bankName }
                }
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Umbenennen", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
            }
        }
        .padding(20)
        .onAppear {
            switch target {
            case let .bank(connection): name = connection.displayName
            case let .account(account): name = model.displayName(of: account)
            }
        }
    }

    private func save() {
        let entered = name
        isSaving = true
        Task {
            let failure: String? = switch target {
            case let .bank(connection):
                await model.renameConnection(connection.id, to: entered)
            case let .account(account):
                // The bank's own name again: drop the custom one instead of storing a copy.
                await model.renameAccount(account.id, to: entered.trimmingCharacters(in: .whitespacesAndNewlines) == model.bankName(of: account.id) ? nil : entered)
            }
            isSaving = false
            if let failure { error = failure } else { dismiss() }
        }
    }
}

extension View {
    func renameSheet(_ target: Binding<RenameTarget?>) -> some View {
        sheet(item: target) { RenameSheet(target: $0) }
    }
}
