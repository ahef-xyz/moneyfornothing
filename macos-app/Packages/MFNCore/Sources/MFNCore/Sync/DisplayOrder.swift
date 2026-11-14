import Foundation

/// User-defined order of banks and their accounts in the sidebar (a UI preference, not ledger data).
///
/// Stores IDs only. Items not in the order (new banks/accounts) keep their natural order and go
/// after the ordered ones; IDs that no longer exist are ignored and dropped on the next move.
public struct DisplayOrder: Codable, Equatable, Sendable {
    public var connections: [String]
    /// Account order per connection (`ConnectionID.rawValue` → `AccountID.rawValue`s).
    public var accounts: [String: [String]]

    public init(connections: [String] = [], accounts: [String: [String]] = [:]) {
        self.connections = connections
        self.accounts = accounts
    }

    /// `items` in the stored order; unknown items after them, in their original order.
    public static func ordered<Item>(_ items: [Item], by order: [String], id: (Item) -> String) -> [Item] {
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return items.enumerated().sorted { a, b in
            switch (rank[id(a.element)], rank[id(b.element)]) {
            case let (x?, y?): x < y
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil): a.offset < b.offset
            }
        }.map(\.element)
    }

    /// Moves `dragged` to the position of `target` in `ids` (drag and drop onto an item):
    /// dragging down lands after the target, dragging up before it.
    public static func move(_ dragged: String, onto target: String, in ids: [String]) -> [String] {
        guard let from = ids.firstIndex(of: dragged), let to = ids.firstIndex(of: target), from != to else { return ids }
        var result = ids
        result.remove(at: from)
        result.insert(dragged, at: to)
        return result
    }

    /// Moves `id` one step up (`offset` −1) or down (+1); unchanged at the edges.
    public static func move(_ id: String, by offset: Int, in ids: [String]) -> [String] {
        guard let from = ids.firstIndex(of: id) else { return ids }
        let to = from + offset
        guard ids.indices.contains(to) else { return ids }
        var result = ids
        result.swapAt(from, to)
        return result
    }

    /// `List.onMove` semantics: moves the elements at `source` to before `destination`.
    public static func move(fromOffsets source: IndexSet, toOffset destination: Int, in ids: [String]) -> [String] {
        let moving = source.sorted().map { ids[$0] }
        var result = ids.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let insertAt = destination - source.filter { $0 < destination }.count
        result.insert(contentsOf: moving, at: max(0, min(insertAt, result.count)))
        return result
    }
}
