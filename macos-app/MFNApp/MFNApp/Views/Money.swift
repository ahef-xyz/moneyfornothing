import MFNCore
import SwiftUI

enum Money {
    /// The common case, built once (lists format thousands of amounts).
    private static let euro = Decimal.FormatStyle.Currency(code: "EUR", locale: Locale(identifier: "de_DE"))

    static func format(_ cents: Int, currency: String = "EUR", signed: Bool = false) -> String {
        let value = Decimal(cents) / 100
        let text = currency == "EUR"
            ? value.formatted(euro)
            : value.formatted(.currency(code: currency).locale(Locale(identifier: "de_DE")))
        return signed && cents > 0 ? "+" + text : text
    }
}

/// Where an amount is shown; each area has its own "negative in red" setting.
enum AmountArea {
    case sidebar, ledger, menuBar
}

extension EnvironmentValues {
    @Entry var amountArea: AmountArea = .ledger
}

/// The three "negative in red" settings, read once in `AppModel` for every `AmountText`.
struct NegativeRedAreas: Equatable {
    var sidebar = false
    var ledger = false
    var menuBar = false

    static func current(_ defaults: UserDefaults = .standard) -> NegativeRedAreas {
        NegativeRedAreas(
            sidebar: defaults.bool(forKey: Preferences.negativeRedSidebar),
            ledger: defaults.bool(forKey: Preferences.negativeRedLedger),
            menuBar: defaults.bool(forKey: Preferences.negativeRedMenuBar)
        )
    }

    func contains(_ area: AmountArea) -> Bool {
        switch area {
        case .sidebar: sidebar
        case .ledger: ledger
        case .menuBar: menuBar
        }
    }
}

/// Amount label: monospaced digits, green only for inflows (CLAUDE.md §6 UI), hideable with ⇧⌘H.
/// Negative amounts turn red only if the user switched it on for this area (the minus sign stays,
/// so colour never carries the meaning alone).
struct AmountText: View {
    let cents: Int
    var currency = "EUR"
    var colorsInflow = true
    /// Prefix inflows with "+" (transaction amounts, not balances).
    var signed = false
    /// Secondary instead of primary text colour for neutral amounts (bank totals).
    var muted = false
    @Environment(AppModel.self) private var model
    @Environment(\.amountArea) private var area

    private var highlightsNegative: Bool { model.negativeRed.contains(area) }

    private var style: AnyShapeStyle {
        if model.hideAmounts { return muted ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary) }
        if cents < 0, highlightsNegative { return AnyShapeStyle(Color.red) }
        if colorsInflow, cents > 0 { return AnyShapeStyle(Color.green) }
        return muted ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary)
    }

    var body: some View {
        Text(model.hideAmounts ? "•••••" : Money.format(cents, currency: currency, signed: signed))
            .monospacedDigit()
            .foregroundStyle(style)
            .accessibilityLabel(model.hideAmounts ? "Betrag ausgeblendet" : Money.format(cents, currency: currency, signed: signed))
    }
}

extension View {
    /// VoiceOver reads "Betrag ausgeblendet" instead of the bullets while amounts are hidden.
    @ViewBuilder
    func hiddenAmountLabel(_ hidden: Bool) -> some View {
        if hidden { accessibilityLabel("Betrag ausgeblendet") } else { self }
    }
}

enum DayFormat {
    /// "heute, 08:42" / "gestern, 18:10" / "6. Nov., 09:15"
    static func syncTime(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        if calendar.isDateInToday(date) { return "heute, \(time)" }
        if calendar.isDateInYesterday(date) { return "gestern, \(time)" }
        return date.formatted(.dateTime.day().month(.abbreviated)) + ", " + time
    }

    /// "12. Nov. 2026" for a bank day (bank time zone, German).
    static func short(_ day: BankDay) -> String {
        day.startDate.formatted(Date.FormatStyle(locale: Locale(identifier: "de_DE"), timeZone: BankDay.bankTimeZone).day().month(.abbreviated).year())
    }

    /// Short form for the sidebar header: time today, otherwise the date.
    static func shortSyncTime(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
            : date.formatted(.dateTime.day().month(.abbreviated))
    }
}
