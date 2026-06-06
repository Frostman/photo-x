import XCTest
import IndexingCore
@testable import PhotoX

/// Verifies the production build is self-contained: ExifTool is bundled inside
/// the .app, Perl modules load correctly, and `ExifToolRunner` resolves to
/// that bundled binary (not the Homebrew dev fallback).
///
/// Test bundle's `Bundle.main` is the test runner, NOT PhotoX.app. We use
/// `Bundle(for: type(of: self))` to find the test bundle, but the actual
/// `exiftool/` folder is inside PhotoX.app — so we walk to the host app.
final class BundledResourcesTests: XCTestCase {

    /// Locates PhotoX.app from the running test bundle. The test runs as a
    /// loadable bundle inside `PhotoX.app/Contents/PlugIns/PhotoXTests.xctest/`,
    /// so the .app is two `deletingLastPathComponent` calls up.
    private func locatePhotoXAppResources() throws -> URL {
        let testBundleURL = Bundle(for: type(of: self)).bundleURL
        // .../PhotoX.app/Contents/PlugIns/PhotoXTests.xctest
        //  → up → PlugIns
        //  → up → Contents
        //  → up → PhotoX.app
        let appURL = testBundleURL
            .deletingLastPathComponent()  // PlugIns/
            .deletingLastPathComponent()  // Contents/
            .deletingLastPathComponent()  // PhotoX.app
        return appURL.appendingPathComponent("Contents/Resources")
    }

    func test_exiftool_isBundled_inAppResources() throws {
        let resources = try locatePhotoXAppResources()
        let exiftool = resources.appendingPathComponent("exiftool/exiftool")
        XCTAssertTrue(
            FileManager.default.isExecutableFile(atPath: exiftool.path),
            "exiftool must be bundled at \(exiftool.path)"
        )
    }

    func test_exiftool_runs_andPerlModulesLoad() throws {
        let resources = try locatePhotoXAppResources()
        let exiftool = resources.appendingPathComponent("exiftool/exiftool")
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: exiftool.path),
            "exiftool missing — bootstrap.sh probably hasn't run"
        )

        let process = Process()
        process.executableURL = exiftool
        process.arguments = ["-ver"]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        let outStr = String(
            data: stdout.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let errStr = String(
            data: stderr.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        XCTAssertEqual(process.terminationStatus, 0,
                       "exiftool -ver exited \(process.terminationStatus); stderr: \(errStr)")
        XCTAssertFalse(outStr.isEmpty, "exiftool -ver should print a version")
        XCTAssertNil(errStr.range(of: "Can't locate"),
                     "Perl module load failure (missing Image::ExifTool/* path?): \(errStr)")
    }

    func test_exifToolRunner_resolvesToBundledPath() {
        let path = ExifToolRunner.exifToolPath
        XCTAssertTrue(
            path.contains(".app/Contents/Resources/exiftool/exiftool"),
            "ExifToolRunner must prefer the bundled binary in production, got: \(path)"
        )
    }
}
