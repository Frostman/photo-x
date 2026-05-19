import Foundation

/// Batched reader that pulls EVERYTHING per-pair metadata needs from
/// exiftool in a single subprocess spawn. Reads:
///
///   - Sony AF tags (focus location, focal-plane points, faces, AF settings)
///   - Orientation (numeric, for AF-rect transforms)
///   - Sony:SequenceNumber (drives the filmstrip burst bracket overlay)
///   - The EXIF / TIFF / Aux fields that populate `ExifSummary` for the sidebar
///
/// One subprocess for ~50 URLs replaces what used to be N exiftool spawns
/// (one per pair for AF) + N CGImageSource opens (one per pair for EXIF) +
/// a separate exiftool batch (for SequenceNumber). Since exiftool's cost is
/// per-file-opened, not per-tag-read, folding everything into one invocation
/// is essentially free relative to the AF-only spawn we had before.
///
/// This loader is the SOLE production caller of exiftool (and of the per-pair
/// metadata reading paths in general — see `project_indexer_sole_loader`).
/// `ImageIOMetadata.read(from:)` and `ExifToolRunner.readAF(from:)` remain
/// in the tree for tests + debugging but are not used by the running app.
enum MetadataBatchLoader {
    struct Result: Sendable {
        var af:   [String: ExifToolRunner.AFData] = [:]   // by SourceFile path
        var exif: [String: ExifSummary]           = [:]   // by SourceFile path
        var seq:  [String: Int]                   = [:]   // by SourceFile path
    }

    /// Subprocess wall time vs in-process JSON parse time for one batch.
    /// Logged per batch by the indexer so we can see whether the cost is
    /// inside exiftool (file open + tag scan, dominated by spawn cold-start
    /// on small batches) or in our Swift parsing (rare).
    struct Stats: Sendable, Hashable {
        var filesIn:  Int    = 0
        var bytesOut: Int    = 0
        var spawnMS:  Double = 0   // process.run() → waitUntilExit() + stdout drain
        var parseMS:  Double = 0   // JSONSerialization + per-entry build
    }

    /// Tags fetched per file. Order matters only for readability; exiftool
    /// returns them all in the same JSON object regardless. Adding new tags
    /// is essentially free — the dominant cost is opening the file.
    private static let tagArgs: [String] = [
        // ── Sony AF ───────────────────────────────────────────────────────
        "-Sony:FocusLocation", "-Sony:FocusFrameSize",
        "-Sony:FocalPlaneAFPointArea",
        "-Sony:FocalPlaneAFPointLocation1", "-Sony:FocalPlaneAFPointLocation2",
        "-Sony:FocalPlaneAFPointLocation3", "-Sony:FocalPlaneAFPointLocation4",
        "-Sony:FocalPlaneAFPointLocation5", "-Sony:FocalPlaneAFPointLocation6",
        "-Sony:FocalPlaneAFPointLocation7", "-Sony:FocalPlaneAFPointLocation8",
        "-Sony:FocalPlaneAFPointLocation9",
        "-Sony:FocalPlaneAFPointsUsed",
        "-Sony:FocusMode", "-Sony:AFAreaModeSetting", "-Sony:AFAreaMode",
        "-Sony:AFTracking",
        "-Sony:Face1Position", "-Sony:Face2Position", "-Sony:Face3Position",
        "-Sony:Face4Position", "-Sony:Face5Position", "-Sony:Face6Position",
        "-Sony:FacesDetected",
        "-Composite:FocusDistance", "-Composite:FocusDistance2",
        "-Orientation#",   // numeric (1-8) so AF rects can be transformed
        // ── Sony burst sequence ──────────────────────────────────────────
        "-Sony:SequenceNumber",
        // ── EXIF (sidebar) ───────────────────────────────────────────────
        "-EXIF:Make", "-EXIF:Model",
        "-EXIF:LensModel", "-ExifIFD:LensModel",
        "-EXIF:FNumber", "-EXIF:ExposureTime", "-EXIF:ISO",
        "-EXIF:FocalLength", "-EXIF:ExposureCompensation",
        "-EXIF:DateTimeOriginal",
        "-Composite:ImageSize",   // "WxH" works across HEIF + ARW
    ]

    /// Convenience wrapper that drops stats. Kept for tests / debugging.
    nonisolated static func read(_ urls: [URL]) -> Result {
        readInstrumented(urls).result
    }

    /// Run one exiftool spawn over `urls` and return parsed per-pair data
    /// alongside per-batch timing stats. Empty Result + nil stats on any
    /// failure — caller treats missing entries as "not yet indexed".
    nonisolated static func readInstrumented(_ urls: [URL])
        -> (result: Result, stats: Stats?)
    {
        guard !urls.isEmpty else { return (Result(), nil) }
        guard FileManager.default.isExecutableFile(atPath: ExifToolRunner.exifToolPath) else {
            return (Result(), nil)
        }
        // `-n` disables exiftool's pretty-printing for numeric fields so we
        // get raw Doubles for FNumber / ExposureTime / etc. instead of
        // strings like "f/5.6" or "1/200" that we'd then have to re-parse.
        var args: [String] = ["-j", "-G1", "-n"]
        args.append(contentsOf: tagArgs)
        args.append("--")
        args.append(contentsOf: urls.map { $0.path })
        let t0 = CFAbsoluteTimeGetCurrent()
        let data: Data
        do {
            data = try runJSONArray(arguments: args)
        } catch {
            Log.app.error("MetadataBatchLoader: \(String(describing: error), privacy: .public)")
            return (Result(), nil)
        }
        let t1 = CFAbsoluteTimeGetCurrent()
        let parsed = parse(jsonData: data)
        let t2 = CFAbsoluteTimeGetCurrent()
        let stats = Stats(
            filesIn:  urls.count,
            bytesOut: data.count,
            spawnMS:  (t1 - t0) * 1000.0,
            parseMS:  (t2 - t1) * 1000.0
        )
        return (parsed, stats)
    }

    /// Parse the array-of-objects JSON shape that `exiftool -j` emits, and
    /// demux it into the three per-source dicts. Each entry yields zero or
    /// more entries across the dicts depending on which tags are present;
    /// absence of a tag is silently fine.
    static func parse(jsonData data: Data) -> Result {
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return Result()
        }
        var out = Result()
        for entry in arr {
            guard let source = entry["SourceFile"] as? String else { continue }
            if let af = parseAF(from: entry) { out.af[source] = af }
            let exif = ExifSummary.from(exiftoolDict: entry)
            if exif != ExifSummary() { out.exif[source] = exif }
            if let seq = sequenceNumber(in: entry), seq > 0 { out.seq[source] = seq }
        }
        return out
    }

    /// Rebuild ExifToolRunner.AFData from an exiftool entry using the
    /// existing pure parsers in ExifToolRunner. Returns nil only when the
    /// entry has no AF data at all — i.e. nothing to surface.
    private static func parseAF(from dict: [String: Any]) -> ExifToolRunner.AFData? {
        let orientation = ExifToolRunner.parseOrientation(from: dict)
        let rawSize = ExifToolRunner.parseRawImageSize(from: dict)
        let rawRegions = ExifToolRunner.parseRegions(from: dict)
        let settings = ExifToolRunner.parseSettings(from: dict)
        let regions = rawRegions.map { region in
            AFRegion(
                kind: region.kind,
                rect: ExifToolRunner.transform(region.rect,
                                               orientation: orientation,
                                               rawSize: rawSize),
                label: region.label
            )
        }
        if regions.isEmpty && settings == AFSettings() {
            return nil
        }
        return ExifToolRunner.AFData(regions: regions, settings: settings)
    }

    /// `Sony:SequenceNumber` may come back as Int, NSNumber, or String. With
    /// `-G1` the key is group-prefixed; older exiftool builds occasionally
    /// drop the prefix, so check the bare key too.
    private static func sequenceNumber(in entry: [String: Any]) -> Int? {
        for key in ["Sony:SequenceNumber", "SequenceNumber"] {
            if let i = entry[key] as? Int { return i }
            if let n = entry[key] as? NSNumber { return n.intValue }
            if let s = entry[key] as? String, let i = Int(s) { return i }
        }
        return nil
    }

    enum BatchLoaderError: Error {
        case launchFailed(String)
        case nonZeroExit(Int32, String)
    }

    private static func runJSONArray(arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ExifToolRunner.exifToolPath)
        process.arguments = arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do { try process.run() } catch {
            throw BatchLoaderError.launchFailed(error.localizedDescription)
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            throw BatchLoaderError.nonZeroExit(process.terminationStatus,
                                               String(data: errData, encoding: .utf8) ?? "")
        }
        return stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    }
}
