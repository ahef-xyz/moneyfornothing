import MFNCore
import SwiftUI

// MARK: - Catalog helpers

extension CategoryID {
    /// Title from the catalog; unknown IDs (older catalog) show their raw value.
    var title: String { CategoryCatalog.title(self) }
    var symbol: String { CategoryCatalog.info(self)?.symbol ?? "tag" }
    /// Position in the catalog, for sorting like the picker; unknown IDs last.
    var catalogIndex: Int { CategoryFormat.catalogIndex[self] ?? .max }
}

extension CategorySource {
    var title: String {
        switch self {
        case .rule: "Regel"
        case .knn: "Ähnliche Buchungen"
        case .llm: "KI (Foundation Models, auf dem Mac)"
        case .manual: "Manuell"
        }
    }

    /// Short marker in list chips. Rule and manual need none (they are certain).
    var shortTitle: String? {
        switch self {
        case .knn: "ähnlich"
        case .llm: "KI"
        case .rule, .manual: nil
        }
    }

    var symbol: String {
        switch self {
        case .rule: "list.bullet.rectangle"
        case .knn: "point.3.connected.trianglepath.dotted"
        case .llm: "apple.intelligence"
        case .manual: "hand.point.up.left"
        }
    }
}

enum CategoryFormat {
    static let catalogIndex: [CategoryID: Int] = Dictionary(
        uniqueKeysWithValues: CategoryCatalog.all.enumerated().map { ($1.id, $0) }
    )

    static func confidence(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(2)).locale(Locale(identifier: "de_DE")))
    }

    /// "Regel" / "KI · Konfidenz 0,64" – for tooltips.
    static func provenance(_ transaction: MFNCore.Transaction) -> String {
        guard let source = transaction.categorySource else { return "Quelle unbekannt" }
        guard source != .manual, let confidence = transaction.confidence else { return source.title }
        return "\(source.title) · Konfidenz \(Self.confidence(confidence))"
    }

    /// Catalog grouped for pickers, optionally filtered by a search text.
    static func groups(matching search: String = "") -> [(group: CategoryInfo.Group, items: [CategoryInfo])] {
        let words = fold(search).split(separator: " ").map(String.init)
        return CategoryInfo.Group.allCases.compactMap { group in
            let items = CategoryCatalog.all.filter { info in
                guard info.group == group else { return false }
                let haystack = fold(info.title + " " + group.title + " " + info.id.rawValue)
                return words.allSatisfy(haystack.contains)
            }
            return items.isEmpty ? nil : (group, items)
        }
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de_DE"))
            .trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Chip

/// Category in a list row: symbol + title, and for machine suggestions a text marker ("KI",
/// "ähnlich") – the source is never shown by colour alone.
struct CategoryChip: View {
    let transaction: MFNCore.Transaction

    var body: some View {
        if let category = transaction.categoryID {
            HStack(spacing: 3) {
                Image(systemName: category.symbol)
                    .imageScale(.small)
                    .accessibilityHidden(true)
                Text(category.title)
                if let short = transaction.categorySource?.shortTitle {
                    Text("· \(short)")
                }
            }
            .font(.caption)
            .lineLimit(1)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .help("\(category.title) · \(CategoryFormat.provenance(transaction))")
            .accessibilityElement(children: .combine)
        }
    }
}

// MARK: - Context menu

/// Context menu of the transaction list (right click on one or several rows).
struct TransactionContextMenu: View {
    let ids: Set<TransactionID>
    @Environment(AppModel.self) private var model

    var body: some View {
        if !ids.isEmpty {
            let reviewable = model.reviewable(ids)
            if !reviewable.isEmpty {
                Button(reviewable.count == 1 ? "Vorschlag übernehmen" : "\(reviewable.count) Vorschläge übernehmen") {
                    model.acceptSuggestions(for: ids)
                }
            }
            Button("Kategorie zuweisen …") { model.showCategoryPicker(for: ids) }
            if ids.count == 1, let id = ids.first {
                Button("Regel erstellen …") { model.showRuleEditor(for: id) }
            }
        }
    }
}

// MARK: - Picker sheet (⌘K)

struct CategoryPickerRequest: Identifiable {
    let id = UUID()
    let transactionIDs: [TransactionID]
    /// Counterpart of a single transaction, or "3 Umsätze".
    let title: String
    /// Category all targets share, highlighted at first.
    let current: CategoryID?
}

/// Row of the picker: a catalog category or "Keine Kategorie".
enum CategoryChoice: Hashable {
    case none
    case category(CategoryID)

    var categoryID: CategoryID? {
        if case let .category(id) = self { id } else { nil }
    }
}

struct CategoryPickerSheet: View {
    let request: CategoryPickerRequest
    /// Set by the setup assistant: gets the choice instead of `AppModel.categoryPicker`
    /// (`nil` argument with `cancelled` = closed without a choice).
    var onFinish: ((_ choice: CategoryID?, _ cancelled: Bool) -> Void)?
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var selection: CategoryChoice?
    @FocusState private var searchFocused: Bool

    private var groups: [(group: CategoryInfo.Group, items: [CategoryInfo])] {
        CategoryFormat.groups(matching: search)
    }

    private var showsNone: Bool {
        let folded = CategoryFormat.fold(search)
        return folded.isEmpty || CategoryFormat.fold("Keine Kategorie").contains(folded)
    }

    /// Rows top to bottom, for the arrow keys in the search field.
    private var choices: [CategoryChoice] {
        (showsNone ? [.none] : []) + groups.flatMap { $0.items.map { .category($0.id) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Kategorie zuweisen")
                    .font(.headline)
                Text(request.title)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            TextField("Kategorie suchen", text: $search)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onSubmit { choose(selection ?? choices.first) }
                .onKeyPress(.downArrow) { move(by: 1) }
                .onKeyPress(.upArrow) { move(by: -1) }
            List(selection: $selection) {
                if showsNone {
                    Label("Keine Kategorie", systemImage: "tag.slash")
                        .tag(CategoryChoice.none)
                }
                ForEach(groups, id: \.group) { entry in
                    Section(entry.group.title) {
                        ForEach(entry.items) { info in
                            Label(info.title, systemImage: info.symbol)
                                .tag(CategoryChoice.category(info.id))
                        }
                    }
                }
            }
            .contextMenu(forSelectionType: CategoryChoice.self) { _ in
            } primaryAction: { picked in
                choose(picked.first)
            }
            .overlay {
                if choices.isEmpty { ContentUnavailableView.search(text: search) }
            }
            HStack {
                Text("⏎ oder Doppelklick weist zu")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Abbrechen", role: .cancel) { cancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Zuweisen") { choose(selection) }
                    .disabled(selection == nil)
            }
        }
        .padding(16)
        .frame(width: 380, height: 520)
        .onAppear {
            selection = request.current.map(CategoryChoice.category)
            searchFocused = true
        }
        .onChange(of: search) {
            if let selection, choices.contains(selection) { return }
            selection = choices.first
        }
    }

    private func move(by offset: Int) -> KeyPress.Result {
        let list = choices
        guard !list.isEmpty else { return .handled }
        let index = selection.flatMap { list.firstIndex(of: $0) }.map { $0 + offset } ?? (offset > 0 ? 0 : list.count - 1)
        selection = list[min(max(index, 0), list.count - 1)]
        return .handled
    }

    private func cancel() {
        if let onFinish { onFinish(nil, true) } else { model.categoryPicker = nil }
    }

    private func choose(_ choice: CategoryChoice?) {
        guard let choice else { return }
        if let onFinish {
            onFinish(choice.categoryID, false)
            return
        }
        guard model.categoryPicker?.id == request.id else { return }
        model.categoryPicker = nil
        model.setCategory(choice.categoryID, for: request.transactionIDs)
    }
}

/// Category menu picker grouped like the catalog (rule editor).
struct CategoryMenuPicker: View {
    @Binding var selection: CategoryID?

    var body: some View {
        Picker("Kategorie", selection: $selection) {
            Text("Bitte wählen").tag(CategoryID?.none)
            ForEach(CategoryFormat.groups(), id: \.group) { entry in
                Section(entry.group.title) {
                    ForEach(entry.items) { info in
                        Label(info.title, systemImage: info.symbol).tag(CategoryID?.some(info.id))
                    }
                }
            }
        }
    }
}
