import AppKit
import MFNCore
import SwiftUI

/// "In Zwischenablage kopieren" for the account header: bank details, IBAN, BIC, German account
/// number and bank code, balances, and the GiroCode.
///
/// Every entry shows the value it copies, so nothing is copied blind. The IBAN goes out without
/// spaces (what transfer forms accept), the bank details as a ready-to-send block. A checkmark
/// confirms the copy where the menu was opened.
struct AccountCopyMenu: View {
    let account: Account
    let balance: Balance?
    let bankName: String?
    /// Owned by the header, so its context menu can open the GiroCode here too.
    @Binding var showsGiroCode: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var copied = false
    @State private var resetCopied: Task<Void, Never>?

    var body: some View {
        Menu {
            AccountCopyItems(account: account, balance: balance, bankName: bankName,
                             onCopy: confirm, onShowGiroCode: { showsGiroCode = true })
        } label: {
            // Both labels always laid out, only one visible: swapping them must not change the
            // width (the row would shift).
            ZStack {
                Label("Kontodaten", systemImage: "building.columns").opacity(copied ? 0 : 1)
                Label("Kopiert", systemImage: "checkmark").opacity(copied ? 1 : 0)
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: copied)
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .fixedSize()
        .help("Bankverbindung, IBAN, Kontostand kopieren oder GiroCode anzeigen")
        .accessibilityLabel(copied ? "Kopiert" : "Kontodaten")
        .popover(isPresented: $showsGiroCode, arrowEdge: .bottom) {
            if let iban = account.iban {
                GiroCodeView(holder: NSFullUserName(), iban: iban, bic: BICLookup.institution(forIBAN: iban)?.bic)
            }
        }
    }

    private func confirm() {
        copied = true
        AccessibilityNotification.Announcement("Kopiert").post()
        // A second copy restarts the 1.5 s instead of an older timer clearing it early.
        resetCopied?.cancel()
        resetCopied = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            copied = false
        }
    }
}

/// The menu entries, shared by the header's copy button and its context menu: everything to copy
/// in one group, then the GiroCode under its own heading.
struct AccountCopyItems: View {
    let account: Account
    let balance: Balance?
    let bankName: String?
    var onCopy: () -> Void = {}
    var onShowGiroCode: () -> Void = {}
    @Environment(AppModel.self) private var model

    var body: some View {
        Section("In Zwischenablage kopieren") {
            if account.iban != nil {
                entry("Bankverbindung", value: [holder, institution?.name ?? bankName ?? ""].filter { !$0.isEmpty }.joined(separator: " · "),
                      copies: details, symbol: "building.columns")
            }
            if let iban = account.iban {
                entry("IBAN", value: IBANFormat.grouped(iban), copies: iban.filter { !$0.isWhitespace }, symbol: "number")
            }
            if let bic {
                entry("BIC", value: bic, copies: bic, symbol: "globe.europe.africa")
            }
            if let legacy = account.iban.flatMap(GermanAccountNumber.init(iban:)) {
                entry("Kontonummer", value: legacy.accountNumber, copies: legacy.accountNumber, symbol: "textformat.123")
                entry("BLZ", value: legacy.bankCode, copies: legacy.bankCode, symbol: "building.2")
            }
            if let balance {
                amountEntry("Kontostand", cents: balance.bookedCents, balance: balance, symbol: "eurosign")
                if let available = balance.availableCents {
                    amountEntry("Verfügbar", cents: available, balance: balance, symbol: "creditcard")
                }
            }
        }
        if let iban = account.iban, !holder.isEmpty, GiroCode.payload(name: holder, iban: iban, bic: bic) != nil {
            Section("Geld anfordern") {
                Button(action: onShowGiroCode) {
                    Label {
                        Text("GiroCode anzeigen …")
                        Text("QR-Code zum Überweisen an dieses Konto")
                    } icon: {
                        Image(systemName: "qrcode")
                    }
                }
            }
        }
    }

    /// Banks do not report the account holder, so the name is the Mac user's full name.
    private var holder: String { NSFullUserName() }
    private var institution: BICLookup.Institution? { account.iban.flatMap(BICLookup.institution(forIBAN:)) }
    private var bic: String? { institution?.bic }

    /// As it goes into an e-mail or invoice:
    ///
    ///     Name: Erika Mustermann
    ///     IBAN: DE02 1203 0000 0000 2020 51
    ///     BIC: BYLADEM1001 (DKB)
    private var details: String {
        var lines: [String] = []
        if !holder.isEmpty { lines.append("Name: \(holder)") }
        if let iban = account.iban { lines.append("IBAN: \(IBANFormat.grouped(iban))") }
        if let institution { lines.append("BIC: \(institution.bic) (\(institution.name))") }
        return lines.joined(separator: "\n")
    }

    /// Copies "1.234,56 € (Stand 14.11.2026)": a pasted balance says when it was current.
    private func amountEntry(_ title: String, cents: Int, balance: Balance, symbol: String) -> some View {
        let amount = Money.format(cents, currency: balance.currency)
        let date = balance.asOf.formatted(.dateTime.day(.twoDigits).month(.twoDigits).year().locale(Locale(identifier: "de_DE")))
        let text = "\(amount) (Stand \(date))"
        return entry(title, value: model.hideAmounts ? "••••• (Stand \(date))" : text, copies: text, symbol: symbol)
    }

    private func entry(_ title: String, value: String, copies text: String, symbol: String) -> some View {
        Button {
            NSPasteboard.general.copyConcealed(text)
            onCopy()
        } label: {
            Label {
                Text(title)
                Text(value)
            } icon: {
                Image(systemName: symbol)
            }
        }
        .accessibilityLabel("\(title) kopieren")
        .accessibilityValue(value)
    }
}

/// The GiroCode (EPC QR code) for this account: scanned with a banking app, it fills in a
/// transfer to the account. Shown, never sent anywhere; MFN itself moves no money.
private struct GiroCodeView: View {
    let holder: String
    let iban: String
    /// Made once per popover, not on every update (CoreImage render).
    @State private var image: NSImage?
    @State private var copied = false
    @State private var resetCopied: Task<Void, Never>?

    init(holder: String, iban: String, bic: String?) {
        self.holder = holder
        self.iban = iban
        _image = State(initialValue: GiroCode.payload(name: holder, iban: iban, bic: bic).flatMap(QRCodeImage.make))
    }

    var body: some View {
        VStack(spacing: 12) {
            if let image {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 200, height: 200)
                    .padding(10)
                    .background(.white)
                    // Name and IBAN are read from the text below.
                    .accessibilityLabel("GiroCode")
                VStack(spacing: 2) {
                    Text(holder).font(.headline)
                    Text(IBANFormat.grouped(iban)).monospaced().foregroundStyle(.secondary)
                }
                Text("Mit der Banking-App scannen, um an dieses Konto zu überweisen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                Button(copied ? "Kopiert" : "Bild kopieren", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    NSPasteboard.general.copyConcealed(image)
                    copied = true
                    AccessibilityNotification.Announcement("Kopiert").post()
                    resetCopied?.cancel()
                    resetCopied = Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        guard !Task.isCancelled else { return }
                        copied = false
                    }
                }
                .controlSize(.small)
            }
        }
        // The header row is single-line; its limit must not reach the popover.
        .lineLimit(nil)
        .padding(16)
        .frame(width: 260)
    }
}

extension NSPasteboard {
    /// Copies an image flagged concealed/transient like `copyConcealed(_:)`: the GiroCode holds
    /// name and IBAN, so clipboard managers should skip it too.
    func copyConcealed(_ image: NSImage) {
        let markers = [NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
                       NSPasteboard.PasteboardType("org.nspasteboard.TransientType")]
        clearContents()
        writeObjects([image])
        addTypes(markers, owner: nil)
        for marker in markers { setString("", forType: marker) }
    }
}

/// EPC069-12 "SEPA Credit Transfer" QR payload (GiroCode), version 002 (BIC optional), UTF-8.
/// No amount, no purpose: the payer fills those in.
enum GiroCode {
    static func payload(name: String, iban: String, bic: String?) -> String? {
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(70))
        let iban = iban.filter { !$0.isWhitespace }.uppercased()
        guard !name.isEmpty, (15...34).contains(iban.count) else { return nil }
        return ["BCD", "002", "1", "SCT", bic ?? "", name, iban].joined(separator: "\n")
    }
}

/// Account number and bank code inside a German IBAN (DEpp BBBBBBBB KKKKKKKKKK), for forms that
/// still ask for them. The account number drops its leading zeros, as banks print it.
struct GermanAccountNumber: Equatable {
    let bankCode: String
    let accountNumber: String

    init?(iban: String) {
        let compact = iban.filter { !$0.isWhitespace }.uppercased()
        guard compact.count == 22, compact.hasPrefix("DE"), compact.dropFirst(2).allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        bankCode = String(compact.dropFirst(4).prefix(8))
        let number = compact.dropFirst(12).drop { $0 == "0" }
        guard !number.isEmpty else { return nil }
        accountNumber = String(number)
    }
}

/// BIC and bank name from the bank code inside the IBAN, for the banks MFN connects to. Accounts
/// carry no BIC (no connector reports one), and a wrong BIC is worse than none: unknown codes
/// return nil.
enum BICLookup {
    struct Institution: Equatable {
        let bic: String
        let name: String
    }

    static func institution(forIBAN iban: String) -> Institution? {
        let compact = iban.filter { !$0.isWhitespace }.uppercased()
        switch compact.prefix(2) {
        case "DE":
            guard compact.count == 22 else { return nil }
            return german[String(compact.dropFirst(4).prefix(8))]
        case "AT":
            guard compact.count == 20 else { return nil }
            return austrian[String(compact.dropFirst(4).prefix(5))]
        default:
            return nil
        }
    }

    private static let german: [String: Institution] = [
        "50010517": Institution(bic: "INGDDEFF", name: "ING"),
        "12030000": Institution(bic: "BYLADEM1001", name: "DKB"),
        "10011001": Institution(bic: "NTSBDEB1", name: "N26"),
        "10010178": Institution(bic: "TRBKDEBB", name: "Trade Republic"),
        "50024024": Institution(bic: "DEFFDEFF", name: "C24 Bank"),
    ]

    private static let austrian: [String: Institution] = [
        "14200": Institution(bic: "EASYATW1", name: "easybank"),
    ]
}

/// Syncs the account's bank connection from the header (same as ⇧⌘R). Spins while that bank is
/// syncing or waiting for an approval, so a second tap cannot start a parallel sync; VoiceOver
/// hears when it starts and when it waits for an approval.
struct AccountSyncButton: View {
    let connectionID: ConnectionID
    /// False for invisible measuring copies, so an announcement is posted once.
    var announces = true
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var phase: SyncState.Phase { model.syncState(connectionID).phase }

    private var isBusy: Bool {
        switch phase {
        case .syncing, .waitingForApproval: true
        case .idle, .failed, .storeFailed: false
        }
    }

    /// What VoiceOver announces when the phase changes; nil for the end states (the result shows
    /// in the sidebar and as an alert).
    private var announcement: String? {
        switch phase {
        case .syncing: "Abgleich läuft"
        case .waitingForApproval: "Warte auf Freigabe"
        case .idle, .failed, .storeFailed: nil
        }
    }

    var body: some View {
        Button {
            model.syncConnection(connectionID)
        } label: {
            Label {
                Text(isBusy ? "Wird abgeglichen …" : "Abgleichen")
            } icon: {
                Image(systemName: "arrow.clockwise")
                    .symbolEffect(.rotate, options: .repeat(.continuous), isActive: isBusy && !reduceMotion)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(isBusy || model.lock.isLocked)
        .help("Dieses Konto abgleichen (⇧⌘R)")
        .onChange(of: announcement) { _, text in
            guard announces, let text else { return }
            AccessibilityNotification.Announcement(text).post()
        }
    }
}
