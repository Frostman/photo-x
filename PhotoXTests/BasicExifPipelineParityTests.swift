import XCTest
import IndexingCore
@testable import PhotoX

/// End-to-end parity check for the basic-EXIF + thumbs pipeline.
///
/// Drives `ThumbnailLoader.loadInstrumented(from:)` — the SAME entry
/// point the indexer uses — for every HIF and JPG in `sample/`, then
/// compares each `ExifSummary` field-by-field against a single batched
/// `exiftool` run over the exact same files.
///
/// ARW files are intentionally excluded: the basic-EXIF pipeline only
/// runs on the preview (HIF/JPG) for paired entries — RAWs never reach
/// `ThumbnailLoader`. Standalone HIFs and JPGs are both covered.
///
/// Skipped automatically when `sample/` or `exiftool` aren't present in
/// the dev environment (CI without bundled fixtures, etc.).
final class BasicExifPipelineParityTests: XCTestCase {

    private static let sampleDir = RepoSample.url

    /// Extensions that the basic-EXIF pipeline actually processes.
    /// Matches the dispatch in `ThumbnailLoader.extractEmbedded`.
    private static let pipelineExtensions: Set<String> =
        ["hif", "heif", "heic", "jpg", "jpeg"]

    func test_basicExifPipeline_matchesExiftool_forEveryImageInSampleFolder() throws {
        // Gate on the dev environment: skip if the fixture or tool is missing.
        let urls: [URL]
        do {
            urls = try FileManager.default
                .contentsOfDirectory(at: Self.sampleDir,
                                     includingPropertiesForKeys: nil,
                                     options: [.skipsHiddenFiles,
                                               .skipsSubdirectoryDescendants])
                .filter {
                    Self.pipelineExtensions.contains(
                        $0.pathExtension.lowercased()
                    )
                }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            throw XCTSkip("sample/ not available: \(error)")
        }
        guard !urls.isEmpty else {
            throw XCTSkip("no pipeline-eligible images in sample/")
        }
        guard FileManager.default.isExecutableFile(
            atPath: ExifToolRunner.exifToolPath
        ) else {
            throw XCTSkip("exiftool not available")
        }

        // ── Pipeline-side: one ExifSummary per file via the real loader.
        var pipelineSummaries: [String: ExifSummary] = [:]
        for url in urls {
            let result = ThumbnailLoader.loadInstrumented(from: url)
            guard let summary = result.exif else {
                XCTFail("\(url.lastPathComponent): basic-EXIF pipeline returned no ExifSummary")
                continue
            }
            pipelineSummaries[url.path] = summary
        }

        // ── Oracle: one batched exiftool spawn covering every file.
        let oracleSummaries = exiftoolSummaries(for: urls)
        XCTAssertEqual(oracleSummaries.count, urls.count,
                       "exiftool returned \(oracleSummaries.count) entries for \(urls.count) files")

        // ── Field-by-field comparison. Every mismatch is a failure with
        //    the filename in the message so a regression points at a
        //    specific sample, not the whole batch.
        for url in urls {
            let name = url.lastPathComponent
            guard let ours = pipelineSummaries[url.path] else { continue }
            guard let oracle = oracleSummaries[url.path] else {
                XCTFail("\(name): exiftool produced no entry")
                continue
            }
            XCTAssertEqual(ours.camera,               oracle.camera,               "\(name): camera mismatch")
            XCTAssertEqual(ours.lens,                 oracle.lens,                 "\(name): lens mismatch")
            XCTAssertEqual(ours.aperture,             oracle.aperture,             "\(name): aperture mismatch")
            XCTAssertEqual(ours.shutterSpeed,         oracle.shutterSpeed,         "\(name): shutter speed mismatch")
            XCTAssertEqual(ours.iso,                  oracle.iso,                  "\(name): ISO mismatch")
            XCTAssertEqual(ours.focalLength,          oracle.focalLength,          "\(name): focal length mismatch")
            XCTAssertEqual(ours.exposureCompensation, oracle.exposureCompensation, "\(name): exposure comp mismatch")
            XCTAssertEqual(ours.orientation,          oracle.orientation,          "\(name): orientation mismatch")
            XCTAssertEqual(ours.pixelWidth,           oracle.pixelWidth,           "\(name): pixelWidth mismatch")
            XCTAssertEqual(ours.pixelHeight,          oracle.pixelHeight,          "\(name): pixelHeight mismatch")
            XCTAssertEqual(ours.dateTime,             oracle.dateTime,             "\(name): dateTime mismatch")
        }
    }

    // MARK: - exiftool batched oracle

    /// One exiftool spawn covering every URL. Requests exactly the tag
    /// set `ExifSummary.from(exiftoolDict:)` consumes; `-G1` adds group
    /// prefixes that match the lookup keys; `-n` returns raw numerics
    /// (no locale-dependent print conversions).
    /// Returns a dict keyed by the absolute path of each input file
    /// (matches exiftool's `SourceFile` field).
    private func exiftoolSummaries(for urls: [URL]) -> [String: ExifSummary] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ExifToolRunner.exifToolPath)
        var args: [String] = [
            "-j", "-G1", "-n",
            "-EXIF:Make", "-EXIF:Model",
            "-EXIF:LensModel", "-ExifIFD:LensModel",
            "-EXIF:FNumber", "-EXIF:ExposureTime", "-EXIF:ISO",
            "-EXIF:FocalLength", "-EXIF:ExposureCompensation",
            "-EXIF:DateTimeOriginal",
            "-IFD0:Orientation", "-EXIF:Orientation",
            "-Composite:ImageSize",
            "--",
        ]
        args.append(contentsOf: urls.map(\.path))
        process.arguments = args

        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return [:] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let arr = (try? JSONSerialization.jsonObject(with: data))
                as? [[String: Any]] else { return [:] }
        var byPath: [String: ExifSummary] = [:]
        for entry in arr {
            // SourceFile is the absolute path as exiftool sees it. Use
            // standardized URL paths on both sides so case / symlink
            // differences don't desync the dict.
            guard let source = entry["SourceFile"] as? String else { continue }
            let canonical = URL(fileURLWithPath: source).standardizedFileURL.path
            byPath[canonical] = ExifSummary.from(exiftoolDict: entry)
        }
        // Re-key against the input URLs' standardized paths so the
        // caller's lookups by `url.path` find a hit even if the input
        // URL wasn't standardized.
        var byInputPath: [String: ExifSummary] = [:]
        for url in urls {
            let canonical = url.standardizedFileURL.path
            if let s = byPath[canonical] { byInputPath[url.path] = s }
        }
        return byInputPath
    }
}
