import Foundation
import Testing
@testable import MFNFinTS

@Suite struct WireTests {
    @Test func parsesEscapesGroupsAndEmptyPositions() throws {
        // ISO-8859-1 bytes, as banks send them ("ü" is one byte).
        let latin1 = try FinTSWire.latin1Bytes("HIRMS:4:2:3+0020::Auftrag ausgeführt.+3040::Weitere Daten?: folgen:AB?+12?'3'")
        let segments = try FinTSWire.parse(latin1)
        #expect(segments.count == 1)
        let segment = try #require(segments.first)
        #expect(segment.type == "HIRMS")
        #expect(segment.number == 4)
        #expect(segment.version == 2)
        #expect(segment.reference == 3)
        #expect(segment[0][0] == "0020")
        #expect(segment[0][1] == nil)
        #expect(segment[0][2] == "Auftrag ausgeführt.")
        #expect(segment[1][2] == "Weitere Daten: folgen")
        #expect(segment[1][3] == "AB+12'3")
    }

    @Test func binaryMayContainSeparators() throws {
        let payload = Data("a'b+c:d?e@f".utf8)
        let segment = FinTSSegment(type: "HNVSD", version: 1, number: 999, elements: [.binary(payload)])
        let encoded = try FinTSWire.encode([segment])
        #expect(String(decoding: encoded, as: UTF8.self) == "HNVSD:999:1+@11@a'b+c:d?e@f'")
        let parsed = try FinTSWire.parse(encoded)
        #expect(parsed.first?[0].components.first??.binary == payload)
    }

    @Test func roundTripTrimsTrailingEmpties() throws {
        let segment = FinTSSegment(type: "HKKAZ", version: 7, number: 3, elements: [
            FinTSDataElement(texts: ["DE00123", nil, "1234567890", nil, "280", "50010517"]),
            "N", .empty, .empty, .empty, .empty,
        ])
        let encoded = try FinTSWire.encode([segment])
        #expect(String(decoding: encoded, as: UTF8.self) == "HKKAZ:3:7+DE00123::1234567890::280:50010517+N'")
        let parsed = try #require(try FinTSWire.parse(encoded).first)
        #expect(parsed[0][5] == "50010517")
        #expect(parsed[1].first == "N")
    }

    @Test func escapesSpecialCharactersInText() throws {
        let segment = FinTSSegment(type: "HKXYZ", version: 1, number: 2, elements: ["Mustermann's Firma + Co: 100% @home?"])
        let encoded = String(decoding: try FinTSWire.encode([segment]), as: UTF8.self)
        #expect(encoded == "HKXYZ:2:1+Mustermann?'s Firma ?+ Co?: 100% ?@home??'")
        #expect(try FinTSWire.parse(Array(encoded.utf8)).first?[0].first == "Mustermann's Firma + Co: 100% @home?")
    }

    @Test func rejectsNonLatin1() {
        let segment = FinTSSegment(type: "HKXYZ", version: 1, number: 2, elements: ["10 €"])
        #expect(throws: FinTSWireError.notLatin1("€")) { try FinTSWire.encode([segment]) }
    }

    @Test func rejectsTruncatedInput() {
        #expect(throws: FinTSWireError.self) { try FinTSWire.parse(Array("HNHBK:1:3+000".utf8)) }
        #expect(throws: FinTSWireError.self) { try FinTSWire.parse(Array("HNVSD:999:1+@20@abc'".utf8)) }
    }

    @Test func ignoresLineBreaksBetweenSegments() throws {
        let segments = try FinTSWire.parse(Array("HIRMG:2:2+0010::OK'\r\nHIRMS:3:2:3+0020::OK'\n".utf8))
        #expect(segments.map(\.type) == ["HIRMG", "HIRMS"])
    }
}
