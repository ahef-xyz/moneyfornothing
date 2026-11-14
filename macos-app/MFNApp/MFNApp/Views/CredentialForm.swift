import MFNCore
import SwiftUI

/// Inputs for `ConnectorID.credentialFields` (setup assistant, "Zugangsdaten ändern…", missing
/// credentials during a headless login). Values stay in memory until saved to the keychain.
struct CredentialForm: View {
    let fields: [CredentialField]
    @Binding var values: [String: String]

    init(fields: [CredentialField], values: Binding<[String: String]>) {
        self.fields = fields
        self._values = values
    }

    init(connector: ConnectorID, values: Binding<[String: String]>) {
        self.init(fields: connector.credentialFields, values: values)
    }

    var body: some View {
        ForEach(fields) { field in
            let binding = Binding(get: { values[field.key] ?? "" }, set: { values[field.key] = $0 })
            Group {
                if field.isSecret {
                    SecureField(field.label, text: binding, prompt: field.prompt.isEmpty ? nil : Text(field.prompt))
                } else {
                    TextField(field.label, text: binding, prompt: field.prompt.isEmpty ? nil : Text(field.prompt))
                        .textContentType(contentType(field))
                        .autocorrectionDisabled()
                }
            }
            .monospacedDigit()
        }
    }

    private func contentType(_ field: CredentialField) -> NSTextContentType? {
        switch field.kind {
        case .email: .username
        case .phone: .telephoneNumber
        case .text: .username
        case .secret: .password
        }
    }

    /// Short hint for an incomplete form, `nil` when complete.
    static func problem(_ values: [String: String], for connector: ConnectorID) -> String? {
        problem(values, fields: connector.credentialFields)
    }

    static func problem(_ values: [String: String], fields: [CredentialField]) -> String? {
        for field in fields {
            let value = values[field.key] ?? ""
            if value.isEmpty { return "\(field.label) fehlt." }
            if field.isNumeric, !value.allSatisfy(\.isNumber) { return "\(field.label): nur Ziffern." }
            if let length = field.length, value.count != length { return "\(field.label): genau \(length) Zeichen." }
        }
        return nil
    }

    /// Trims whitespace around non-secret values (copied phone numbers, e-mail addresses).
    static func cleaned(_ values: [String: String], for connector: ConnectorID) -> BankCredentials {
        cleaned(values, fields: connector.credentialFields)
    }

    static func cleaned(_ values: [String: String], fields: [CredentialField]) -> BankCredentials {
        var result = BankCredentials()
        for field in fields {
            let value = values[field.key] ?? ""
            result[field.key] = field.isSecret ? value : value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }
}

/// Fixed note under credential inputs.
struct CredentialNote: View {
    var body: some View {
        Label("MFN liest nur – keine Überweisungen, keine Aufträge. Die Zugangsdaten bleiben im Schlüsselbund dieses Macs und werden nur an die Bank gesendet.", systemImage: "lock.shield")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
