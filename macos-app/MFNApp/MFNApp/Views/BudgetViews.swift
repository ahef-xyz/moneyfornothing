import MFNCore
import SwiftUI

enum BudgetFormat {
    private static let locale = Locale.autoupdatingCurrent

    /// "November", "Q4 2026", "2026", or "25. Okt. – 24. Nov." for shifted periods.
    static func periodTitle(_ status: BudgetStatus) -> String {
        let start = status.range.lowerBound, end = status.range.upperBound
        let short = Date.FormatStyle(locale: locale, timeZone: BankDay.bankTimeZone).day().month(.abbreviated)
        // Calendar names only for exact calendar periods (an income anchor may shift them).
        let calendarAligned = start.day == 1 && end.adding(days: 1).day == 1
        switch status.budget.period {
        case .monthly where calendarAligned && start.month == end.month:
            return start.startDate.formatted(Date.FormatStyle(locale: locale, timeZone: BankDay.bankTimeZone).month(.wide))
        case .quarterly where calendarAligned && (start.month - 1) % 3 == 0:
            return "Q\((start.month - 1) / 3 + 1) \(start.year)"
        case .yearly where calendarAligned && start.month == 1:
            return "\(start.year)"
        default:
            return "\(start.startDate.formatted(short)) – \(end.startDate.formatted(short))"
        }
    }

    static func stateText(_ status: BudgetStatus, hide: Bool) -> String {
        let money = { (c: Int) in hide ? "•••••" : Money.format(c) }
        switch status.state {
        case .onTrack: return String(localized: "Prognose \(money(status.forecastCents)) – im Rahmen")
        case .atRisk: return String(localized: "Prognose \(money(status.forecastCents)) – \(money(status.forecastCents - status.budget.amountCents)) über Budget")
        case .exceeded: return String(localized: "\(money(status.spentCents - status.budget.amountCents)) über Budget")
        }
    }

    static func breakdown(_ status: BudgetStatus, hide: Bool) -> String {
        let money = { (c: Int) in hide ? "•••••" : Money.format(c) }
        let short = Date.FormatStyle(locale: locale, timeZone: BankDay.bankTimeZone).day().month(.abbreviated)
        let asOf = status.dataAsOf < BankDay.today ? String(localized: "Stand der Daten: \(status.dataAsOf.startDate.formatted(short)) – danach geschätzt\n") : ""
        let anchor = status.budget.anchor.map { a in
            if let counterpart = a.counterpart {
                String(localized: "Zeitraum beginnt mit der Aufladung von „\(counterpart)“ (± \(a.toleranceDays) Tage um den \(status.budget.startDay).)\n")
            } else {
                String(localized: "Zeitraum beginnt mit der Aufladung (± \(a.toleranceDays) Tage um den \(status.budget.startDay).)\n")
            }
        } ?? ""
        return asOf + anchor + String(localized: """
        Ausgegeben \(money(status.spentCents)) (ohne Umbuchungen, abzüglich Erstattungen)
        + geplant \(money(status.plannedCents))
        + erwartete Fixkosten \(money(status.expectedRecurringCents))
        + übliche Ausgaben für \(status.daysLeft) Tage \(money(status.expectedVariableCents))
        = Prognose \(money(status.forecastCents)) bei Budget \(money(status.budget.amountCents))
        """)
    }
}

/// Budget in the account header: bar (spent solid, expected lighter, budget mark) plus text.
/// The state is in the text, never only in the colour.
struct BudgetBar: View {
    let status: BudgetStatus
    @Environment(AppModel.self) private var model

    private var warn: Bool { status.state != .onTrack }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("Budget \(BudgetFormat.periodTitle(status))")
                    .fontWeight(.medium)
                Text("\(amount(status.spentCents)) von \(amount(status.budget.amountCents))")
                    .monospacedDigit()
                    .hiddenAmountLabel(model.hideAmounts)
                if status.remainingCents > 0 {
                    Text("· noch \(amount(status.remainingCents))")
                        .monospacedDigit()
                        .hiddenAmountLabel(model.hideAmounts)
                        .foregroundStyle(.secondary)
                    if status.daysLeft > 0 {
                        Text("(\(amount(status.perDayCents))/Tag)")
                            .monospacedDigit()
                            .hiddenAmountLabel(model.hideAmounts)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if status.dataAsOf < BankDay.today {
                    Text("Stand \(status.dataAsOf.startDate.formatted(.dateTime.day().month(.abbreviated).locale(Locale.autoupdatingCurrent)))")
                        .foregroundStyle(.secondary)
                }
                Label(BudgetFormat.stateText(status, hide: model.hideAmounts), systemImage: warn ? "exclamationmark.triangle" : "checkmark.circle")
                    .monospacedDigit()
                    .accessibilityLabel(model.hideAmounts ? String(localized: "Budgetstatus, Beträge ausgeblendet") : BudgetFormat.stateText(status, hide: false))
                    .foregroundStyle(warn ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
            }
            .font(.callout)
            .lineLimit(1)
            bar
                .frame(height: 4)
                .help(BudgetFormat.breakdown(status, hide: model.hideAmounts))
        }
        .accessibilityElement(children: .combine)
    }

    private var bar: some View {
        GeometryReader { geometry in
            let scale = max(1, status.forecastFraction, status.spentFraction) * 1.04
            let width = geometry.size.width
            let spent = width * min(status.spentFraction / scale, 1)
            let forecast = width * min(status.forecastFraction / scale, 1)
            let budgetX = width / scale
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(warn ? Color.orange.opacity(0.35) : Color.primary.opacity(0.18))
                    .frame(width: max(forecast, spent))
                Capsule().fill(warn ? Color.orange : Color.primary.opacity(0.55))
                    .frame(width: spent)
                Rectangle().fill(.primary)
                    .frame(width: 1.5, height: 8)
                    .offset(x: budgetX - 0.75)
            }
        }
    }

    private func amount(_ cents: Int) -> String {
        model.hideAmounts ? "•••••" : Money.format(cents)
    }
}

/// Small ring next to an account in the sidebar: share of the budget spent.
struct BudgetRing: View {
    let status: BudgetStatus
    @Environment(AppModel.self) private var model

    /// State in words without amounts (the ring may be read while amounts are hidden).
    private var stateWord: String { Self.stateWord(status) }

    static func stateWord(_ status: BudgetStatus) -> String {
        switch status.state {
        case .onTrack: String(localized: "im Rahmen")
        case .atRisk: String(localized: "Prognose über Budget")
        case .exceeded: String(localized: "über Budget")
        }
    }

    var body: some View {
        // Budget will not fit: a warning sign instead of the pie (shape, not only colour).
        Group {
            if status.state == .onTrack {
                // A filled pie: at sidebar size a thin stroke made 80 % look like little.
                ZStack {
                    Circle().fill(.quaternary)
                    PieSlice(fraction: min(status.spentFraction, 1))
                        .fill(Color.primary.opacity(0.65))
                    Circle().strokeBorder(.tertiary, lineWidth: 0.5)
                }
            } else {
                Image(systemName: status.state == .exceeded ? "exclamationmark.triangle.fill" : "exclamationmark.triangle")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.orange)
            }
        }
        .frame(width: 12, height: 12)
        .help("Budget \(BudgetFormat.periodTitle(status)): \(Int((status.spentFraction * 100).rounded())) % ausgegeben · \(BudgetFormat.stateText(status, hide: model.hideAmounts))")
        .accessibilityLabel("Budget \(Int((status.spentFraction * 100).rounded())) Prozent ausgegeben, \(stateWord)")
    }
}

/// Set, change or remove the budget of an account.
struct BudgetSheet: View {
    let account: Account
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var amountText = ""
    @State private var period: AccountBudget.Period = .monthly
    @State private var startDay = 1
    @State private var anchored = false
    @State private var tolerance = 3
    /// Empty = automatic (largest deposit).
    @State private var anchorCounterpart = ""
    @State private var error: String?

    private var existing: AccountBudget? { model.budget(for: account.id) }

    private var cents: Int? { BudgetSheet.parseCents(amountText) }

    /// Amounts in German or English style → cents; `nil` if not a positive amount.
    /// Both "," and "." present: the last one is the decimal separator ("1.234,50", "1,234.50").
    /// Only one kind: once with 1–2 trailing digits it is the decimal separator ("12,5", "12.50"),
    /// otherwise it groups thousands ("2.000", "2,000", "1.000.000").
    static func parseCents(_ text: String) -> Int? {
        var cleaned = String(text.replacingOccurrences(of: "€", with: "")
            .filter { !$0.isWhitespace && $0 != "'" && $0 != "\u{2019}" }
            .map { char -> Character in
                if char == "\u{066B}" { return "." }
                if char.isASCII { return char }
                if let digit = char.wholeNumberValue, digit < 10 { return Character(Unicode.Scalar(UInt8(48 + digit))) }
                return char
            })
        let comma = cleaned.lastIndex(of: ","), dot = cleaned.lastIndex(of: ".")
        if let comma, let dot {
            let (decimal, grouping): (Character, Character) = comma > dot ? (",", ".") : (".", ",")
            cleaned = cleaned.filter { $0 != grouping }.map { $0 == decimal ? "." : String($0) }.joined()
        } else if let separator = comma ?? dot {
            let mark = cleaned[separator]
            let trailing = cleaned.distance(from: separator, to: cleaned.endIndex) - 1
            if cleaned.filter({ $0 == mark }).count == 1, (1...2).contains(trailing) {
                cleaned = cleaned.map { $0 == mark ? "." : String($0) }.joined()
            } else {
                cleaned = cleaned.filter { $0 != mark }
            }
        }
        if cleaned.filter({ $0 == "." }).count > 1 { return nil }
        guard cleaned.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
              let value = Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX")), value > 0,
              value < 1_000_000_000 else { return nil }
        var scaled = value * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        let cents = NSDecimalNumber(decimal: rounded).intValue
        return cents > 0 ? cents : nil
    }

    private var draft: AccountBudget? {
        cents.map {
            AccountBudget(
                accountID: account.id, amountCents: $0, period: period, startDay: startDay,
                anchor: anchored ? .init(toleranceDays: tolerance, counterpart: anchorCounterpart) : nil
            )
        }
    }

    /// Counterparts topping up this account in at least two different months: anchor choices.
    private var depositSources: [String] {
        var months: [String: Set<Int>] = [:]
        var names: [String: String] = [:]
        for t in model.ledger.transactions(of: account.id) where t.amountCents > 0 && t.status == .booked {
            let key = t.counterpartName.lowercased()
            guard !key.isEmpty else { continue }
            months[key, default: []].insert(t.effectiveDate.year * 12 + t.effectiveDate.month)
            names[key] = names[key] ?? t.counterpartName
        }
        return months.filter { $0.value.count >= 2 }.keys.sorted().compactMap { names[$0] }.prefix(12).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(existing == nil ? String(localized: "Budget festlegen") : String(localized: "Budget ändern")).font(.headline)
            Text(account.name).foregroundStyle(.secondary)
            Form {
                TextField("Betrag (€)", text: $amountText, prompt: Text("z. B. 2.000"))
                    .monospacedDigit()
                    .frame(width: 140)
                Picker("Zeitraum", selection: $period) {
                    ForEach(AccountBudget.Period.allCases, id: \.self) { Text("pro \($0.title)").tag($0) }
                }
                if period == .weekly {
                    Picker("Beginnt am", selection: $startDay) {
                        ForEach(1...7, id: \.self) { Text(Self.weekday($0)).tag($0) }
                    }
                } else {
                    Picker("Beginnt am", selection: $startDay) {
                        ForEach(1...28, id: \.self) { Text("\($0).").tag($0) }
                    }
                }
                Toggle("Zeitraum beginnt mit der Aufladung", isOn: $anchored)
                if anchored {
                    Stepper(value: $tolerance, in: 1...(period == .weekly ? 3 : 7)) {
                        Text(tolerance == 1 ? String(localized: "Toleranz ± \(tolerance) Tag") : String(localized: "Toleranz ± \(tolerance) Tage")).monospacedDigit()
                    }
                    Picker("Aufladung von", selection: $anchorCounterpart) {
                        Text("Automatisch (größte Aufladung)").tag("")
                        ForEach(depositSources, id: \.self) { Text($0).tag($0) }
                        if !anchorCounterpart.isEmpty, !depositSources.contains(anchorCounterpart) {
                            Text(anchorCounterpart).tag(anchorCounterpart)
                        }
                    }
                }
            }
            .formStyle(.columns)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Fixed two-line slot: the preview must not make the sheet jump while typing.
            Group {
                if let draft {
                    let status = BudgetForecast.status(for: draft, transactions: model.ledger.transactions(of: account.id))
                    Text("Aktueller Zeitraum: \(BudgetFormat.periodTitle(status)) · bisher \(Money.format(status.spentCents)) · \(BudgetFormat.stateText(status, hide: model.hideAmounts))")
                } else {
                    Text("Betrag eingeben, um den aktuellen Zeitraum und die Prognose zu sehen.")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(2, reservesSpace: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(anchored
                 ? String(localized: "Wird das Konto bis zu \(tolerance) Tage vor oder nach dem Starttag aufgeladen (Gehalt, Umbuchung, Überweisung), beginnt der Zeitraum an diesem Tag. Ohne Aufladung gilt der Starttag. Automatisch zählt nur eine Aufladung ab einem Viertel des Budgets.")
                 : String(localized: "Gezählt werden Ausgaben des Kontos (gebucht und vorgemerkt), abzüglich Erstattungen; Umbuchungen zwischen eigenen Konten zählen nicht."))
                .lineLimit(3, reservesSpace: true)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            HStack {
                if existing != nil {
                    Button("Budget entfernen", role: .destructive) {
                        Task {
                            if let failure = await model.removeBudget(for: account.id) { error = failure } else { dismiss() }
                        }
                    }
                }
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Sichern") {
                    guard let draft else { return }
                    Task {
                        if let failure = await model.saveBudget(draft) { error = failure } else { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft == nil)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            if let existing {
                amountText = RecurringDraft.text(existing.amountCents)
                period = existing.period
                startDay = existing.startDay
                anchored = existing.anchor != nil
                tolerance = existing.anchor?.toleranceDays ?? 3
                anchorCounterpart = existing.anchor?.counterpart ?? ""
            }
        }
        .onChange(of: period) { _, new in
            if new == .weekly, startDay > 7 { startDay = 1 }
            if new == .weekly, tolerance > 3 { tolerance = 3 }
        }
    }

    private static func weekday(_ day: Int) -> String {
        [String(localized: "Montag"), String(localized: "Dienstag"), String(localized: "Mittwoch"), String(localized: "Donnerstag"),
         String(localized: "Freitag"), String(localized: "Samstag"), String(localized: "Sonntag")][day - 1]
    }
}

/// Sector from 12 o'clock clockwise, `fraction` of the full circle.
struct PieSlice: Shape {
    var fraction: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard fraction > 0 else { return path }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        if fraction >= 1 {
            path.addEllipse(in: rect)
            return path
        }
        path.move(to: center)
        path.addArc(center: center, radius: radius, startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * fraction), clockwise: false)
        path.closeSubpath()
        return path
    }
}
