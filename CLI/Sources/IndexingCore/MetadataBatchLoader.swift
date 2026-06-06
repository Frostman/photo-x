import Foundation

/// Batched reader for the **proprietary Sony tags** the indexer needs:
/// AF point locations, AF settings, face positions, Composite focus
/// distance, EXIF Orientation override (Sony:CameraOrientation handles
/// the HEIF pre-rotation case), and Sony:SequenceNumber for the
/// filmstrip burst bracket overlay.
///
/// **Standard EXIF is NOT read here.** The thumbs pipeline extracts the
/// HEIF Exif item bytes alongside the embedded JPEG and parses them
/// with `TIFFEXIFParser`, so Make/Model/Lens/exposure/ImageSize/
/// Orientation arrive without an exiftool round-trip.
///
/// Spawns one exiftool process per batch (50 URLs by default). Warm
/// throughput is ~22 ms / file including the ~1 s cold-start amortised
/// across the batch. We do NOT use exiftool's `-stay_open` mode here —
/// it deadlocks under Foundation `Pipe`s because exiftool buffers
/// stdout 4 KB-at-a-time when stdout isn't a TTY, and the autoflush
/// path doesn't fire reliably (see project memory).
public enum MetadataBatchLoader {
    public struct Result: Sendable {
        public var af:   [String: ExifToolRunner.AFData] = [:]   // by SourceFile path
        public var exif: [String: ExifSummary]           = [:]   // populated by the thumbs+EXIF pipeline, NOT by this loader
        public var seq:  [String: Int]                   = [:]   // by SourceFile path
        public init() {}
    }

    /// Per-batch timing stats. `spawnMS` includes both subprocess
    /// startup and exiftool's per-file scan; `parseMS` is JSON
    /// deserialisation only.
    public struct Stats: Sendable, Hashable {
        public var filesIn:  Int    = 0
        public var bytesOut: Int    = 0
        public var spawnMS:  Double = 0
        public var parseMS:  Double = 0
        public init(filesIn: Int = 0, bytesOut: Int = 0, spawnMS: Double = 0, parseMS: Double = 0) {
            self.filesIn = filesIn
            self.bytesOut = bytesOut
            self.spawnMS = spawnMS
            self.parseMS = parseMS
        }
    }

    /// Tag args sent to exiftool. **Sony-only** — standard EXIF tags
    /// removed since `TIFFEXIFParser` produces them from the HEIF Exif
    /// item bytes the thumbs pipeline already extracted.
    ///
    /// `#` suffix forces RAW (un-print-converted) value for that tag.
    /// Sony enum tags (FocusMode, AFAreaModeSetting, AFTracking) are
    /// LEFT WITHOUT `#` so they come back as friendly strings
    /// ("DMF", "Wide / Multi") that the sidebar can display verbatim.
    public static let tagArgs: [String] = [
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
        // Orientation# / Sony:CameraOrientation# for the AF transform.
        // Sony HIFs don't expose IFD0:Orientation as 1-8 (pre-rotated
        // pixels report 1) — Sony:CameraOrientation in MakerNotes
        // carries the real value. parseOrientation picks whichever
        // the file has.
        "-Orientation#",
        "-Sony:CameraOrientation#",
        // ── Sony burst sequence ──────────────────────────────────────────
        "-Sony:SequenceNumber",
    ]

    /// Convenience wrapper that drops stats. Kept for tests; production
    /// uses `readInstrumented` so it can publish per-batch timings.
    nonisolated public static func read(_ urls: [URL]) async -> Result {
        await readInstrumented(urls).result
    }

    /// Spawn a one-shot exiftool per batch, request the Sony argv +
    /// URLs, parse the JSON into AF + SequenceNumber. Empty Result +
    /// nil stats on any failure — caller treats missing entries as
    /// "not yet indexed".
    nonisolated public static func readInstrumented(_ urls: [URL])
        async -> (result: Result, stats: Stats?)
    {
        guard !urls.isEmpty else { return (Result(), nil) }
        var args: [String] = ["-j", "-G1"]
        args.append(contentsOf: tagArgs)
        args.append("--")
        args.append(contentsOf: urls.map { $0.path })
        let t0 = Date().timeIntervalSinceReferenceDate
        let data = await spawnExiftool(args: args)
        let t1 = Date().timeIntervalSinceReferenceDate
        let parsed = parseSony(jsonData: data)
        let t2 = Date().timeIntervalSinceReferenceDate
        let stats = Stats(
            filesIn:  urls.count,
            bytesOut: data.count,
            spawnMS:  (t1 - t0) * 1000.0,
            parseMS:  (t2 - t1) * 1000.0
        )
        return (parsed, stats)
    }

    private static func spawnExiftool(args: [String]) async -> Data {
        // Skip the spawn entirely when no tool is configured — saves
        // a noisy "file doesn't exist" per batch when the operator
        // already accepted no-AF-data at startup.
        guard !ExifToolRunner.exifToolPath.isEmpty else { return Data() }
        return await withCheckedContinuation { (cont: CheckedContinuation<Data, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let path = ExifToolRunner.exifToolPath
                #if os(Linux)
                // Raw fork+execve bypasses swift-corelibs-foundation's
                // pre-spawn `access()` check that returns EACCES on
                // Nix-store binaries (NixOS). See PosixExec.swift.
                do {
                    let r = try PosixExec.run(executable: path, arguments: args)
                    if r.exitCode != 0 {
                        let stderr = String(data: r.stderr, encoding: .utf8) ?? ""
                        CoreLog.error("exiftool exit \(r.exitCode): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
                    }
                    cont.resume(returning: r.stdout)
                } catch {
                    CoreLog.error("PosixExec: \(String(describing: error))")
                    cont.resume(returning: Data())
                }
                #else
                let process = ExifToolRunner.makeProcess(arguments: args)
                let outPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = Pipe()
                do {
                    try process.run()
                } catch {
                    CoreLog.error("MetadataBatchLoader spawn: \(String(describing: error))")
                    cont.resume(returning: Data())
                    return
                }
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                cont.resume(returning: data)
                #endif
            }
        }
    }

    /// Parse the array-of-objects JSON shape exiftool emits and demux
    /// into AF + SequenceNumber dicts. **Does NOT touch exif** — that
    /// dict is populated by `TIFFEXIFParser` upstream. Each entry
    /// yields zero or more entries depending on which tags are present.
    public static func parseSony(jsonData data: Data) -> Result {
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return Result()
        }
        var out = Result()
        for entry in arr {
            guard let source = entry["SourceFile"] as? String else { continue }
            if let af = parseAF(from: entry) { out.af[source] = af }
            if let seq = sequenceNumber(in: entry), seq > 0 { out.seq[source] = seq }
        }
        return out
    }

    /// Pre-refactor entry point. Kept so MetadataBatchLoaderTests still
    /// compile; the new pipeline doesn't call it. Reads BOTH the Sony
    /// half AND `ExifSummary.from(exiftoolDict:)` for the EXIF half so
    /// the existing parser tests still exercise both code paths.
    public static func parse(jsonData data: Data) -> Result {
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

    /// `Sony:SequenceNumber` may come back as Int, NSNumber, or String.
    /// With `-G1` the key is group-prefixed; older exiftool builds
    /// occasionally drop the prefix, so check the bare key too.
    private static func sequenceNumber(in entry: [String: Any]) -> Int? {
        for key in ["Sony:SequenceNumber", "SequenceNumber"] {
            if let i = entry[key] as? Int { return i }
            if let n = entry[key] as? NSNumber { return n.intValue }
            if let s = entry[key] as? String, let i = Int(s) { return i }
        }
        return nil
    }
}
