import XCTest
@testable import HoopReplay

/// Runs the cross-platform fixture so iOS cuts exactly the clips Android and the Web cut.
final class HighlightClipsTests: XCTestCase {
    /// The fixture's ids, numbers or strings, as row ids.
    private struct FlexId: Decodable {
        let value: RowID
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Int64.self) { value = String(number) } else { value = try container.decode(String.self) }
        }
    }
    private struct Fixture: Decodable {
        struct Seg: Decodable { let sequence: Int; let duration_ms: Int64 }
        struct Ev: Decodable { let team_id: FlexId; let player_id: FlexId?; let type: String; let segment: Int; let segment_time_ms: Int64; let reverted: Int }
        struct Target: Decodable { let player_id: FlexId?; let team_id: FlexId? }
        struct K: Decodable { let segment: Int; let start_ms: Int64; let end_ms: Int64 }
        struct Case: Decodable { let name: String; let target: Target; let clips: [K] }
        let segments: [Seg]; let events: [Ev]; let cases: [Case]
    }

    func testMatchesSharedFixture() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../web/lib/highlight-clips.fixture.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        let segments = fixture.segments.enumerated().map { RecordingSegment(id: String($0.offset), gameId: "g", sequence: $0.element.sequence, uri: "", durationMs: $0.element.duration_ms, createdAt: 0) }
        let events = fixture.events.enumerated().map { i, e in
            StatEvent(id: String(i), gameId: "g", teamId: e.team_id.value, playerId: e.player_id?.value, type: e.type, value: 0, period: 1, gameClockMs: 0, segment: e.segment, segmentTimeMs: e.segment_time_ms, finalVideoTimeMs: 0, reverted: e.reverted != 0)
        }
        for c in fixture.cases {
            let target: HighlightTarget = c.target.player_id.map { .player($0.value) } ?? .team(c.target.team_id!.value)
            XCTAssertEqual(highlightClips(events, segments, target), c.clips.map { Clip(segment: $0.segment, startMs: $0.start_ms, endMs: $0.end_ms) }, c.name)
        }
    }
}
