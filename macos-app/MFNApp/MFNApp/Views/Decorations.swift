import MFNCore
import SwiftUI

/// Merchant monogram (CLAUDE.md §6 UI): 1–2 letters, colour from a stable hash of the name.
/// No brand logos. Status is carried by shape, never by colour alone:
/// booked = solid ring + filled disc, pending = dashed ring + filled disc,
/// planned = dotted ring + tinted (unfilled) disc + clock badge, cancelled = grey.
struct MonogramAvatar: View {
    let name: String
    var status: TransactionStatus = .booked
    var size: CGFloat = 30

    var body: some View {
        let color = Monogram.color(for: name)
        ZStack {
            Circle()
                .strokeBorder(ringColor(color), style: ringStyle)
            Circle()
                .fill(discStyle(color))
                .padding(4)
            Text(Monogram.initials(for: name))
                .font(.system(size: size * 0.36, weight: .semibold))
                .foregroundStyle(initialsStyle(color))
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            if status == .planned {
                Image(systemName: "clock.fill")
                    .font(.system(size: size * 0.32))
                    .foregroundStyle(.secondary)
                    .background(Circle().fill(.background).padding(-1.5))
                    .offset(x: 2, y: 2)
            }
        }
        .accessibilityHidden(true)
    }

    private var ringStyle: StrokeStyle {
        switch status {
        case .booked, .cancelled: StrokeStyle(lineWidth: 1.5)
        case .pending: StrokeStyle(lineWidth: 1.5, dash: [3, 2.5])
        case .planned: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [0.1, 3.4])
        }
    }

    private func ringColor(_ color: Color) -> Color {
        switch status {
        case .cancelled: .secondary.opacity(0.4)
        case .planned: color.opacity(0.8)
        case .booked, .pending: color.opacity(0.55)
        }
    }

    private func discStyle(_ color: Color) -> Color {
        switch status {
        case .cancelled: .secondary.opacity(0.15)
        case .planned: color.opacity(0.15)
        case .booked, .pending: color
        }
    }

    private func initialsStyle(_ color: Color) -> Color {
        switch status {
        case .cancelled: .secondary
        case .planned: color
        case .booked, .pending: .white
        }
    }
}

/// Bank favicon (loaded from the bank's own site), or a rounded square with the bank's initial.
struct BankBadge: View {
    let connection: Connection
    var size: CGFloat = 15
    @Environment(AppModel.self) private var model

    var body: some View {
        if connection.isManual {
            // v10: no bank behind it, so no favicon and no bank colour: a neutral symbol.
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Monogram.bankColor(connection), in: RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
                .accessibilityHidden(true)
        } else if let icon = model.bankIcons[connection.connectorID] {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
                .accessibilityHidden(true)
        } else {
            monogram
        }
    }

    private var monogram: some View {
        Text(Monogram.bankInitials(connection))
            .font(.system(size: size * 0.53, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Monogram.bankColor(connection), in: RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Hint chip in the transaction list. `dashed` marks a status (vorgemerkt, geplant), so the
/// difference never depends on colour alone.
struct HintChip: View {
    let text: String
    var dashed = false
    var muted = false

    var body: some View {
        Text(text)
            .font(.caption)
            .lineLimit(1)
            .foregroundStyle(muted ? .tertiary : .secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background {
                let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
                if dashed || muted {
                    shape.strokeBorder(.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: dashed ? [3, 2] : []))
                } else {
                    shape.fill(.quaternary.opacity(0.6))
                }
            }
    }
}

/// "Neu" / count badge in the accent colour (accent = "Zu prüfen"/new only).
struct AccentBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Color.accentColor, in: Capsule())
    }
}

enum Monogram {
    private static let legalSuffixes: Set<String> = ["gmbh", "ag", "se", "kg", "ug", "co", "&", "e.v.", "mbh", "s.a.", "sa", "ltd", "inc"]

    /// "Hausverwaltung Nord" → HN, "Osteria da Luca" → OL, "Aral" → Ar, "Musterfirma GmbH" → M.
    static func initials(for name: String) -> String {
        let words = name.split(whereSeparator: { $0.isWhitespace || $0 == "-" }).map(String.init)
        let significant = words.filter { word in
            guard let first = word.first, first.isLetter || first.isNumber else { return false }
            return !legalSuffixes.contains(word.lowercased()) && (first.isUppercase || first.isNumber)
        }
        if significant.count >= 2 {
            return significant.prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        }
        guard let word = significant.first ?? words.first, let first = word.first else { return "?" }
        if words.count == 1, word.count > 1 {
            let second = word[word.index(after: word.startIndex)]
            return String(first).uppercased() + String(second).lowercased()
        }
        return String(first).uppercased()
    }

    private static let palette: [Color] = [.blue, .orange, .green, .red, .purple, .pink, .teal, .indigo, .brown, .cyan, .mint]

    /// FNV-1a: `String.hashValue` is seeded per launch and would change colours on every start.
    static func color(for name: String) -> Color {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in name.lowercased().utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return palette[Int(hash % UInt64(palette.count))]
    }

    static func bankInitials(_ connection: Connection) -> String {
        switch connection.connectorID {
        case .ing: "I"
        case .dkb: "D"
        case .tradeRepublic: "TR"
        case .c24: "C"
        case .easybank: "E"
        case .n26: "N"
        case .mock, .manual: String(connection.displayName.prefix(1)).uppercased()
        }
    }

    static func bankColor(_ connection: Connection) -> Color {
        switch connection.connectorID {
        case .ing: .orange
        case .dkb: .blue
        case .tradeRepublic: Color(white: 0.2)
        case .c24: .teal
        // Lime green of the easybank brand (favicon), not the old Barclays/placeholder purple.
        case .easybank: Color(red: 0.45, green: 0.75, blue: 0.27)
        case .n26: Color(red: 0.21, green: 0.63, blue: 0.62)
        case .mock: color(for: connection.displayName)
        case .manual: .gray
        }
    }
}

extension TransactionStatus {
    var isUpcoming: Bool { self == .pending || self == .planned }
}

/// Bank symbol for a bank without connection yet (setup assistant).
struct ConnectorBadge: View {
    let connector: ConnectorID
    var size: CGFloat = 15

    var body: some View {
        BankBadge(connection: Connection(id: "setup", connectorID: connector, displayName: connector.displayName), size: size)
    }
}
