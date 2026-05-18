import XCTest
@testable import PhotoX

/// Tests the JSON parsing surface of ExifToolBurstLoader. We don't spawn
/// exiftool here — the goal is to lock in how the loader handles the
/// various JSON shapes (Int / NSNumber / String value, missing tag,
/// non-burst frames, malformed input) since the production hot path is
/// the parser, not the subprocess plumbing.
final class ExifToolBurstLoaderTests: XCTestCase {

    func test_parse_extractsSequenceNumberWithGroupPrefix() {
        let json = """
        [
          {"SourceFile": "/tmp/a.ARW", "Sony:SequenceNumber": 1},
          {"SourceFile": "/tmp/b.ARW", "Sony:SequenceNumber": 2}
        ]
        """.data(using: .utf8)!
        let out = ExifToolBurstLoader.parse(jsonData: json)
        XCTAssertEqual(out["/tmp/a.ARW"], 1)
        XCTAssertEqual(out["/tmp/b.ARW"], 2)
    }

    func test_parse_acceptsStringSequenceNumber() {
        // Some exiftool builds emit numeric fields as strings.
        let json = """
        [{"SourceFile": "/tmp/a.ARW", "Sony:SequenceNumber": "7"}]
        """.data(using: .utf8)!
        XCTAssertEqual(ExifToolBurstLoader.parse(jsonData: json)["/tmp/a.ARW"], 7)
    }

    func test_parse_acceptsBareKey_withoutGroupPrefix() {
        // -G1 normally prefixes, but older builds occasionally drop it.
        let json = """
        [{"SourceFile": "/tmp/a.ARW", "SequenceNumber": 4}]
        """.data(using: .utf8)!
        XCTAssertEqual(ExifToolBurstLoader.parse(jsonData: json)["/tmp/a.ARW"], 4)
    }

    func test_parse_skipsEntriesMissingSequenceNumber() {
        // Non-burst frames simply have no tag — they must not appear in
        // the output dict (caller treats absence as "not in any burst").
        let json = """
        [
          {"SourceFile": "/tmp/burst.ARW", "Sony:SequenceNumber": 1},
          {"SourceFile": "/tmp/lone.ARW"}
        ]
        """.data(using: .utf8)!
        let out = ExifToolBurstLoader.parse(jsonData: json)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out["/tmp/burst.ARW"], 1)
        XCTAssertNil(out["/tmp/lone.ARW"])
    }

    func test_parse_skipsZeroOrNegativeSequenceNumbers() {
        // 0 / negatives are protocol noise — guard against them so a
        // weird camera doesn't silently produce a "burst" of nothing.
        let json = """
        [
          {"SourceFile": "/tmp/a.ARW", "Sony:SequenceNumber": 0},
          {"SourceFile": "/tmp/b.ARW", "Sony:SequenceNumber": -3}
        ]
        """.data(using: .utf8)!
        XCTAssertTrue(ExifToolBurstLoader.parse(jsonData: json).isEmpty)
    }

    func test_parse_emptyArrayYieldsEmptyDict() {
        XCTAssertTrue(ExifToolBurstLoader.parse(jsonData: Data("[]".utf8)).isEmpty)
    }

    func test_parse_garbageJsonReturnsEmpty() {
        // Defensive: malformed exiftool output (truncation, non-array) must
        // never crash — burst overlay just stays blank.
        let garbage = Data("not json at all".utf8)
        XCTAssertTrue(ExifToolBurstLoader.parse(jsonData: garbage).isEmpty)
    }

    func test_read_emptyURLsList_isNoOp() {
        // Doesn't spawn anything, doesn't throw.
        XCTAssertTrue(ExifToolBurstLoader.read([]).isEmpty)
    }
}
