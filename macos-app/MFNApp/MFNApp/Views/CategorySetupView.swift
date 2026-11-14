import MFNCore
import SwiftUI

/// "Kategorien einrichten": sheet with the steps on the left (like the setup assistants of
/// macOS), the step on the right and the progress on top. Closing keeps every decision.
struct CategorySetupView: View {
    @Bindable var setup: CategorySetup
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            SetupProgressHeader(plan: setup.plan)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            Divider()
            HStack(spacing: 0) {
                SetupStepList(setup: setup)
                    .frame(width: 190)
                Divider()
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            Divider()
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
        .frame(width: 860, height: 600)
        .sheet(item: $setup.picker) { request in
            CategoryPickerSheet(request: request) { choice, cancelled in
                if cancelled { setup.picker = nil } else { setup.picked(choice, request: request) }
            }
        }
    }

    @ViewBuilder private var content: some View {
        if setup.plan == nil {
            ProgressView("Umsätze werden angesehen …")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch setup.step {
            case .overview: SetupOverview(setup: setup)
            case .income, .fixedCost, .counterparty, .transfer: CandidateStepView(setup: setup)
            case .rest: SetupRestView(setup: setup)
            case .done: SetupDoneView(setup: setup)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Schließen") { model.categorySetup = nil }
                .keyboardShortcut(.cancelAction)
                .help("Schließen – getroffene Entscheidungen bleiben als Regeln erhalten")
            if let error = setup.error {
                Text(error)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else if setup.isWorking {
                ProgressView().controlSize(.small)
            }
            Spacer()
            if setup.step != .overview {
                Button("Zurück") { setup.previousStep() }
            }
            switch setup.step {
            case .done:
                Button("Fertig") { model.categorySetup = nil }
                    .keyboardShortcut(.defaultAction)
            case .overview, .rest:
                // In these steps ⏎ goes on; in the candidate steps it takes the suggestion.
                Button(setup.step == .overview ? "Los geht’s" : "Weiter") { setup.nextStep() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(setup.plan == nil)
            default:
                // ⏎ only once the step has nothing left to decide.
                Button("Weiter") { setup.nextStep() }
                    .keyboardShortcut(setup.current == nil ? .defaultAction : nil)
            }
        }
    }
}

// MARK: - Progress

private struct SetupProgressHeader: View {
    let plan: SetupPlan?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Kategorien einrichten")
                    .font(.headline)
                Spacer()
                if let plan {
                    Text("\(CategorySetup.percent(plan.coverage)) der Umsätze / \(CategorySetup.percent(plan.amountCoverage)) des Betrags kategorisiert")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
            }
            ProgressView(value: plan?.coverage ?? 0)
                .progressViewStyle(.linear)
                .animation(.default, value: plan?.coverage)
                .accessibilityLabel("Kategorisiert")
                .accessibilityValue(plan.map { CategorySetup.percent($0.coverage) } ?? "")
        }
    }
}

// MARK: - Step list

private struct SetupStepList: View {
    let setup: CategorySetup

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(CategorySetup.Step.allCases) { step in
                let isEmpty = step.kind != nil && setup.candidates(of: step).isEmpty && setup.plan != nil
                Button {
                    setup.go(to: step)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: step.symbol)
                            .frame(width: 18)
                            .accessibilityHidden(true)
                        Text(step.title)
                        Spacer(minLength: 4)
                        if step.kind != nil, setup.plan != nil {
                            let open = setup.openCount(of: step)
                            if open > 0 {
                                Text("\(open)").monospacedDigit().foregroundStyle(.secondary)
                            } else if !isEmpty {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.secondary)
                                    .accessibilityLabel("erledigt")
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                    .background(
                        step == setup.step ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                    .foregroundStyle(step == setup.step ? AnyShapeStyle(.white) : (isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary)))
                }
                .buttonStyle(.plain)
                .disabled(setup.plan == nil || isEmpty)
                .help(isEmpty ? "Hier gibt es nichts zu entscheiden" : step.title)
            }
            Spacer()
        }
        .padding(10)
    }
}

// MARK: - Overview

private struct SetupOverview: View {
    let setup: CategorySetup

    var body: some View {
        if let plan = setup.initialPlan {
            let open = plan.totalTransactions - plan.categorizedTransactions
            VStack(alignment: .leading, spacing: 16) {
                Text("\(plan.totalTransactions) Umsätze, \(plan.openCounterparts) Gegenparteien – mit \(plan.candidates.count) Entscheidungen ~\(CategorySetup.percent(plan.projectedCoverage))")
                    .font(.title3)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(open) Umsätze haben noch keine sichere Kategorie. Statt jeden einzeln zuzuordnen, entscheidest du pro Gehalt, Vertrag oder Händler einmal – daraus wird eine Regel, die alle bisherigen und künftigen Umsätze dieser Art kategorisiert.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    ForEach(CategorySetup.Step.allCases.filter { $0.kind != nil }) { step in
                        GridRow {
                            Label(step.title, systemImage: step.symbol)
                            Text("\(setup.candidates(of: step).count)")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .gridColumnAlignment(.trailing)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tastatur")
                        .font(.headline)
                    Text("⏎ Vorschlag übernehmen · 1–9 Kategorie wählen · ⌘K alle Kategorien · ⇥ überspringen · ⌫ zurück")
                        .foregroundStyle(.secondary)
                }
                Text("Du kannst jederzeit schließen: jede Entscheidung ist sofort gespeichert. Die Regeln findest du in Einstellungen → Kategorien.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
        }
    }
}

// MARK: - Candidate steps

private struct CandidateStepView: View {
    let setup: CategorySetup

    var body: some View {
        let candidates = setup.candidates(of: setup.step)
        HStack(spacing: 0) {
            List {
                ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
                    CandidateRow(setup: setup, candidate: candidate, isCurrent: index == setup.currentIndex)
                        .contentShape(Rectangle())
                        .onTapGesture { setup.select(candidate) }
                        .listRowBackground(index == setup.currentIndex ? Color.accentColor.opacity(0.15) : Color.clear)
                }
            }
            .listStyle(.inset)
            .frame(width: 250)
            Divider()
            if let candidate = setup.current {
                CandidateDetail(setup: setup, candidate: candidate, position: setup.currentIndex + 1, count: candidates.count)
                    .id(candidate.id)
            } else {
                ContentUnavailableView("Nichts zu entscheiden", systemImage: "checkmark.circle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct CandidateRow: View {
    let setup: CategorySetup
    let candidate: SetupPlan.Candidate
    let isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(candidate.title)
                    .lineLimit(1)
                    .fontWeight(isCurrent ? .semibold : .regular)
                Spacer(minLength: 4)
                AmountText(cents: candidate.monthlyCents ?? candidate.totalCents, signed: true)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                switch setup.outcomes[candidate.id] {
                case let .decided(category, _)?:
                    Image(systemName: "checkmark").accessibilityLabel("entschieden:")
                    Image(systemName: category.symbol).accessibilityHidden(true)
                    Text(category.title)
                case .skipped?:
                    Image(systemName: "forward").accessibilityLabel("übersprungen")
                    Text("übersprungen")
                case nil:
                    if setup.isCovered(candidate) {
                        Image(systemName: "checkmark.circle").accessibilityLabel("erledigt:")
                        Text("durch andere Regel erledigt")
                    } else {
                        Text(candidate.transactionIDs.count == 1 ? "1 Umsatz" : "\(candidate.transactionIDs.count) Umsätze")
                            .monospacedDigit()
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.vertical, 2)
    }
}

private struct CandidateDetail: View {
    let setup: CategorySetup
    let candidate: SetupPlan.Candidate
    let position: Int
    let count: Int
    @Environment(AppModel.self) private var model

    /// What ⏎ takes: the suggestion, else the first choice.
    private var primary: CategoryID? { candidate.suggestion?.categoryID ?? setup.choices(for: candidate).first }

    var body: some View {
        let choices = setup.choices(for: candidate)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(position) von \(count)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text(candidate.title)
                        .font(.title3)
                        .lineLimit(2)
                    Text(candidate.match.summary)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        Text("Umsätze").foregroundStyle(.secondary)
                        Text("\(candidate.transactionIDs.count)").monospacedDigit()
                    }
                    GridRow {
                        Text("Summe").foregroundStyle(.secondary)
                        AmountText(cents: candidate.totalCents, signed: true)
                    }
                    if let monthly = candidate.monthlyCents {
                        GridRow {
                            Text("Pro Monat").foregroundStyle(.secondary)
                            AmountText(cents: monthly, signed: true)
                        }
                    }
                }
                examples
                suggestion
                VStack(alignment: .leading, spacing: 6) {
                    Text("Kategorie")
                        .font(.headline)
                    LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 6) {
                        ForEach(Array(choices.enumerated()), id: \.element) { index, category in
                            Button {
                                setup.decide(category)
                            } label: {
                                HStack(spacing: 6) {
                                    KeyCap(text: "\(index + 1)")
                                    Label(category.title, systemImage: category.symbol)
                                        .lineLimit(1)
                                        .fontWeight(category == candidate.suggestion?.categoryID ? .semibold : .regular)
                                    if category == candidate.suggestion?.categoryID {
                                        Text("Vorschlag")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    if decidedCategory == category {
                                        Image(systemName: "checkmark").accessibilityLabel("gewählt")
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [])
                            .help("\(category.title) (Taste \(index + 1))")
                        }
                    }
                }
                HStack {
                    Button {
                        setup.acceptSuggestion()
                    } label: {
                        if let primary {
                            Label("\(primary.title) übernehmen", systemImage: primary.symbol)
                        } else {
                            Text("Übernehmen")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(choices.isEmpty)
                    .help("Übernehmen (⏎)")
                    Button("Andere Kategorie …") { setup.showPickerForCurrent() }
                        .keyboardShortcut("k", modifiers: .command)
                        .help("Alle Kategorien (⌘K)")
                    Spacer()
                    Button("Zurück") { setup.back() }
                        .keyboardShortcut(.delete, modifiers: [])
                        .help("Vorheriger Vorschlag (⌫)")
                    Button("Überspringen") { setup.skip() }
                        .keyboardShortcut(.tab, modifiers: [])
                        .help("Offen lassen (⇥)")
                }
                .disabled(setup.isWorking)
            }
            .padding(20)
        }
    }

    private var decidedCategory: CategoryID? {
        if case let .decided(category, _) = setup.outcomes[candidate.id] { category } else { nil }
    }

    @ViewBuilder private var examples: some View {
        let ids = Set(candidate.transactionIDs.prefix(3))
        let transactions = model.ledger.transactions.filter { ids.contains($0.id) }
            .sorted { $0.valueDate > $1.valueDate }
        if !transactions.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Beispiele")
                    .font(.headline)
                ForEach(transactions) { transaction in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(transaction.valueDate.startDate.formatted(.dateTime.day().month(.abbreviated).year()))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 90, alignment: .leading)
                        Text(transaction.purpose.isEmpty ? transaction.counterpartName : transaction.purpose)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 8)
                        AmountText(cents: transaction.amountCents, currency: transaction.currency, signed: true)
                    }
                    .font(.callout)
                }
            }
        }
    }

    @ViewBuilder private var suggestion: some View {
        if let suggestion = candidate.suggestion {
            HStack(spacing: 6) {
                Image(systemName: suggestion.source.symbol)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Vorschlag: \(suggestion.categoryID.title)")
                Text("(\(CategorySetup.sourceText(suggestion)))")
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("Kein Vorschlag – wähle eine Kategorie.")
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Rest

private struct SetupRestView: View {
    @Bindable var setup: CategorySetup

    var body: some View {
        let transactions = Array(setup.openTransactions.prefix(300))
        VStack(alignment: .leading, spacing: 10) {
            Text("Was übrig bleibt, nach Betrag. Mehrere auswählen und mit ⌘K eine Kategorie zuweisen.")
                .foregroundStyle(.secondary)
                .padding([.horizontal, .top], 20)
            List(selection: $setup.restSelection) {
                ForEach(transactions) { transaction in
                    HStack(spacing: 10) {
                        Text(transaction.valueDate.startDate.formatted(.dateTime.day().month(.abbreviated).year()))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 90, alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(transaction.counterpartName.isEmpty ? "Unbekannt" : transaction.counterpartName)
                                .lineLimit(1)
                            Text(transaction.purpose)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        CategoryChip(transaction: transaction)
                        AmountText(cents: transaction.amountCents, currency: transaction.currency, signed: true)
                            .frame(minWidth: 90, alignment: .trailing)
                    }
                    .tag(transaction.id)
                }
            }
            .listStyle(.inset)
            .overlay {
                if transactions.isEmpty {
                    ContentUnavailableView("Alles kategorisiert", systemImage: "checkmark.circle")
                }
            }
            HStack {
                Text(setup.restSelection.isEmpty ? "\(setup.openTransactions.count) offen" : "\(setup.restSelection.count) ausgewählt")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Kategorie zuweisen …") { setup.showPickerForRest() }
                    .keyboardShortcut("k", modifiers: .command)
                    .disabled(setup.restSelection.isEmpty || setup.isWorking)
            }
            .padding([.horizontal, .bottom], 20)
        }
    }
}

// MARK: - Done

private struct SetupDoneView: View {
    let setup: CategorySetup
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Fertig eingerichtet", systemImage: "checkmark.circle")
                .font(.title3)
            if let plan = setup.plan {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        Text("")
                        Text("vorher").foregroundStyle(.secondary)
                        Text("jetzt").foregroundStyle(.secondary)
                    }
                    GridRow {
                        Text("Umsätze kategorisiert")
                        Text(CategorySetup.percent(setup.initialPlan?.coverage ?? 0)).monospacedDigit()
                        Text(CategorySetup.percent(plan.coverage)).monospacedDigit().fontWeight(.semibold)
                    }
                    GridRow {
                        Text("Betrag kategorisiert")
                        Text(CategorySetup.percent(setup.initialPlan?.amountCoverage ?? 0)).monospacedDigit()
                        Text(CategorySetup.percent(plan.amountCoverage)).monospacedDigit().fontWeight(.semibold)
                    }
                    GridRow {
                        Text("Neue Regeln")
                        Text("")
                        Text("\(setup.decisionCount)").monospacedDigit().fontWeight(.semibold)
                    }
                }
            }
            Text("Neue Umsätze dieser Gegenparteien ordnet MFN ab jetzt selbst zu. Die Regeln kannst du in Einstellungen → Kategorien ändern; den Assistenten öffnest du wieder über Umsatz → Kategorien einrichten …")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.reviewCount > 0 {
                Button("\(model.reviewCount) unsichere Vorschläge prüfen") {
                    model.selection = .review
                    model.categorySetup = nil
                }
            }
        }
        .padding(24)
    }
}

/// A number key shown like a key on the keyboard.
private struct KeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(minWidth: 16)
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.tertiary))
            .accessibilityLabel("Taste \(text)")
    }
}
