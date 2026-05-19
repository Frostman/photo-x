import XCTest
@testable import PhotoX

/// Tests the JSON parsing surface of MetadataBatchLoader (the indexer's
/// sole exiftool entry point). We don't spawn exiftool here — the goal is
/// to lock in how the parser demuxes one entry into three dicts (af, exif,
/// seq), and how it handles the various JSON shapes exiftool can emit.
final class MetadataBatchLoaderTests: XCTestCase {

    // MARK: SequenceNumber demux

    func test_parse_extractsSequenceNumberWithGroupPrefix() {
        let json = """
        [
          {"SourceFile": "/tmp/a.ARW", "Sony:SequenceNumber": 1},
          {"SourceFile": "/tmp/b.ARW", "Sony:SequenceNumber": 2}
        ]
        """.data(using: .utf8)!
        let out = MetadataBatchLoader.parse(jsonData: json).seq
        XCTAssertEqual(out["/tmp/a.ARW"], 1)
        XCTAssertEqual(out["/tmp/b.ARW"], 2)
    }

    func test_parse_acceptsStringSequenceNumber() {
        let json = """
        [{"SourceFile": "/tmp/a.ARW", "Sony:SequenceNumber": "7"}]
        """.data(using: .utf8)!
        XCTAssertEqual(MetadataBatchLoader.parse(jsonData: json).seq["/tmp/a.ARW"], 7)
    }

    func test_parse_acceptsBareKey_withoutGroupPrefix() {
        // -G1 normally prefixes, but older exiftool builds occasionally drop it.
        let json = """
        [{"SourceFile": "/tmp/a.ARW", "SequenceNumber": 4}]
        """.data(using: .utf8)!
        XCTAssertEqual(MetadataBatchLoader.parse(jsonData: json).seq["/tmp/a.ARW"], 4)
    }

    func test_parse_skipsZeroOrNegativeSequenceNumbers() {
        let json = """
        [
          {"SourceFile": "/tmp/a.ARW", "Sony:SequenceNumber": 0},
          {"SourceFile": "/tmp/b.ARW", "Sony:SequenceNumber": -3}
        ]
        """.data(using: .utf8)!
        XCTAssertTrue(MetadataBatchLoader.parse(jsonData: json).seq.isEmpty)
    }

    // MARK: EXIF demux (the new path that subsumes ImageIOMetadata)

    func test_parse_extractsExifSummary_camera_lens_exposure() {
        let json = """
        [{
          "SourceFile": "/tmp/a.ARW",
          "EXIF:Make": "SONY",
          "EXIF:Model": "ILCE-1M2",
          "EXIF:LensModel": "FE 50mm F1.4 GM",
          "EXIF:FNumber": 5.6,
          "EXIF:ExposureTime": 0.005,
          "EXIF:ISO": 400,
          "EXIF:FocalLength": 50.0,
          "EXIF:ExposureCompensation": 0.33,
          "EXIF:DateTimeOriginal": "2026:05:18 14:32:01",
          "Composite:ImageSize": "8640x5760"
        }]
        """.data(using: .utf8)!
        let exif = MetadataBatchLoader.parse(jsonData: json).exif["/tmp/a.ARW"]
        XCTAssertEqual(exif?.camera,       "Sony ILCE-1M2",
                       "Make 'SONY' must be pretty-cased to 'Sony'")
        XCTAssertEqual(exif?.lens,         "FE 50mm F1.4 GM")
        XCTAssertEqual(exif?.aperture,     "f/5.6")
        XCTAssertEqual(exif?.shutterSpeed, "1/200")
        XCTAssertEqual(exif?.iso,          "ISO 400")
        XCTAssertEqual(exif?.focalLength,  "50 mm")
        XCTAssertEqual(exif?.exposureCompensation, "+0.3 EV")
        XCTAssertEqual(exif?.pixelWidth,   8640)
        XCTAssertEqual(exif?.pixelHeight,  5760)
    }

    func test_parse_lensFallbackToExifIFDLensModel() {
        // Some files only carry LensModel in the ExifIFD group.
        let json = """
        [{"SourceFile": "/tmp/a.ARW", "ExifIFD:LensModel": "FE 24-70mm F2.8 GM"}]
        """.data(using: .utf8)!
        let exif = MetadataBatchLoader.parse(jsonData: json).exif["/tmp/a.ARW"]
        XCTAssertEqual(exif?.lens, "FE 24-70mm F2.8 GM")
    }

    func test_parse_shutterSpeedFormatting_subSecondVsAboveHalf() {
        // <0.5 s → "1/N"; ≥0.5 s → "N.N s".
        let fastJson = """
        [{"SourceFile": "/tmp/fast.ARW", "EXIF:ExposureTime": 0.004}]
        """.data(using: .utf8)!
        let slowJson = """
        [{"SourceFile": "/tmp/slow.ARW", "EXIF:ExposureTime": 1.5}]
        """.data(using: .utf8)!
        XCTAssertEqual(MetadataBatchLoader.parse(jsonData: fastJson)
            .exif["/tmp/fast.ARW"]?.shutterSpeed, "1/250")
        XCTAssertEqual(MetadataBatchLoader.parse(jsonData: slowJson)
            .exif["/tmp/slow.ARW"]?.shutterSpeed, "1.5 s")
    }

    func test_parse_emptyExifEntryYieldsNoExifKey() {
        // Entry has SourceFile but nothing useful → no entry in the exif dict.
        let json = """
        [{"SourceFile": "/tmp/blank.ARW"}]
        """.data(using: .utf8)!
        let r = MetadataBatchLoader.parse(jsonData: json)
        XCTAssertNil(r.exif["/tmp/blank.ARW"])
        XCTAssertNil(r.af["/tmp/blank.ARW"])
        XCTAssertNil(r.seq["/tmp/blank.ARW"])
    }

    // MARK: AF demux

    func test_parse_extractsAFData_andTransformsByOrientation() {
        // Landscape (Orientation=1) → no rect change. We rely on
        // ExifToolRunner.parsePrimaryFocus / transform to be correct; this
        // test just verifies the loader actually invokes them.
        let json = """
        [{
          "SourceFile": "/tmp/a.ARW",
          "Sony:FocusLocation": "8640 5760 4320 2880",
          "Sony:FocusFrameSize": "120x120",
          "IFD0:Orientation": 1,
          "Sony:FocusMode": "AF-C"
        }]
        """.data(using: .utf8)!
        let af = MetadataBatchLoader.parse(jsonData: json).af["/tmp/a.ARW"]
        XCTAssertNotNil(af)
        XCTAssertEqual(af?.settings.focusMode, "AF-C")
        XCTAssertTrue(af?.regions.contains(where: { $0.kind == .primaryFocus }) ?? false)
    }

    func test_parse_noAFTags_noAFData() {
        let json = """
        [{"SourceFile": "/tmp/a.ARW", "EXIF:ISO": 100}]
        """.data(using: .utf8)!
        XCTAssertNil(MetadataBatchLoader.parse(jsonData: json).af["/tmp/a.ARW"])
    }

    // MARK: defensive shapes

    func test_parse_skipsEntriesMissingSourceFile() {
        let json = """
        [{"EXIF:ISO": 100}, {"SourceFile": "/tmp/good.ARW", "EXIF:ISO": 200}]
        """.data(using: .utf8)!
        let exif = MetadataBatchLoader.parse(jsonData: json).exif
        XCTAssertEqual(exif.count, 1)
        XCTAssertNotNil(exif["/tmp/good.ARW"])
    }

    func test_parse_emptyArrayYieldsEmptyResult() {
        let r = MetadataBatchLoader.parse(jsonData: Data("[]".utf8))
        XCTAssertTrue(r.af.isEmpty); XCTAssertTrue(r.exif.isEmpty); XCTAssertTrue(r.seq.isEmpty)
    }

    func test_parse_garbageJsonReturnsEmpty() {
        let r = MetadataBatchLoader.parse(jsonData: Data("nope".utf8))
        XCTAssertTrue(r.af.isEmpty); XCTAssertTrue(r.exif.isEmpty); XCTAssertTrue(r.seq.isEmpty)
    }

    func test_read_emptyURLsList_isNoOp() async {
        let r = await MetadataBatchLoader.read([])
        XCTAssertTrue(r.af.isEmpty); XCTAssertTrue(r.exif.isEmpty); XCTAssertTrue(r.seq.isEmpty)
    }
}
