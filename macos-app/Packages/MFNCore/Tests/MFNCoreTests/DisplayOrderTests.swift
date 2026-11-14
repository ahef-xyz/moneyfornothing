import Foundation
import MFNCore
import Testing

@Suite struct DisplayOrderTests {
    @Test func orderedPutsKnownFirstAndKeepsNewInNaturalOrder() {
        let items = ["ing", "dkb", "tr", "c24", "eb"]
        let ordered = DisplayOrder.ordered(items, by: ["c24", "gone", "ing"]) { $0 }
        #expect(ordered == ["c24", "ing", "dkb", "tr", "eb"], "unknown IDs ignored, new ones appended in natural order")
        #expect(DisplayOrder.ordered(items, by: []) { $0 } == items)
    }

    @Test func dragOntoItemLandsAtItsPosition() {
        let ids = ["a", "b", "c", "d"]
        #expect(DisplayOrder.move("a", onto: "c", in: ids) == ["b", "c", "a", "d"], "dragging down lands after the target")
        #expect(DisplayOrder.move("d", onto: "b", in: ids) == ["a", "d", "b", "c"], "dragging up lands before the target")
        #expect(DisplayOrder.move("a", onto: "d", in: ids) == ["b", "c", "d", "a"], "the last position is reachable")
        #expect(DisplayOrder.move("a", onto: "a", in: ids) == ids)
        #expect(DisplayOrder.move("x", onto: "a", in: ids) == ids)
    }

    @Test func stepMoveStopsAtEdges() {
        let ids = ["a", "b", "c"]
        #expect(DisplayOrder.move("b", by: -1, in: ids) == ["b", "a", "c"])
        #expect(DisplayOrder.move("b", by: 1, in: ids) == ["a", "c", "b"])
        #expect(DisplayOrder.move("a", by: -1, in: ids) == ids)
        #expect(DisplayOrder.move("c", by: 1, in: ids) == ids)
    }

    @Test func onMoveSemanticsMatchArrayMove() {
        let ids = ["a", "b", "c", "d", "e"]
        #expect(DisplayOrder.move(fromOffsets: [0], toOffset: 3, in: ids) == ["b", "c", "a", "d", "e"])
        #expect(DisplayOrder.move(fromOffsets: [4], toOffset: 0, in: ids) == ["e", "a", "b", "c", "d"])
        #expect(DisplayOrder.move(fromOffsets: [1, 3], toOffset: 5, in: ids) == ["a", "c", "e", "b", "d"])
        #expect(DisplayOrder.move(fromOffsets: [2], toOffset: 2, in: ids) == ids)
    }

    @Test func roundTripsThroughJSON() throws {
        let order = DisplayOrder(connections: ["c24", "ing"], accounts: ["c24": ["x", "y"]])
        let decoded = try JSONDecoder().decode(DisplayOrder.self, from: JSONEncoder().encode(order))
        #expect(decoded == order)
    }
}
