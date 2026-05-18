import Foundation

/// Batched reader for the per-frame Sony burst-sequence tag. One subprocess
/// per chunk of URLs returns a `[sourcePath: SequenceNumber]` dict that the
/// caller folds into `ViewerState.pairSequenceNumber`.
///
/// `Sony:SequenceNumber` is the 1-based index within a continuous-shooting
/// burst. `Sony:SequenceLength` on the A1 II is just the string `"Continuous"`
/// (the camera doesn't know the final count at write time), so we ignore it
/// and infer burst membership from runs of consecutive +1 sequence numbers
/// in the name-sorted pair list (see `ViewerState.burstIDByStem`).
enum ExifToolBurstLoader {
    /// Read `Sony:SequenceNumber` for every URL in one exiftool spawn.
    /// Returns a dict keyed by source path → sequence number; URLs that
    /// don't expose the tag are simply absent. Empty dict on any spawn /
    /// parse failure — burst overlay degrades silently to "no brackets".
    nonisolated static func read(_ urls: [URL]) -> [String: Int] {
        guard !urls.isEmpty else { return [:] }
        guard FileManager.default.isExecutableFile(atPath: ExifToolRunner.exifToolPath) else {
            return [:]
        }
        var args: [String] = ["-j", "-G1", "-Sony:SequenceNumber", "--"]
        args.append(contentsOf: urls.map { $0.path })
        do {
            let data = try runJSONArray(arguments: args)
            return parse(jsonData: data)
        } catch {
            Log.app.error("ExifToolBurstLoader: \(String(describing: error), privacy: .public)")
            return [:]
        }
    }

    /// Parse the array-of-objects JSON shape that `exiftool -j` emits.
    /// Each entry has a `SourceFile` plus zero or more group-prefixed tags.
    /// Returns only entries where `Sony:SequenceNumber` is present and > 0.
    static func parse(jsonData data: Data) -> [String: Int] {
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return [:]
        }
        var out: [String: Int] = [:]
        for entry in arr {
            guard let source = entry["SourceFile"] as? String,
                  let seq = sequenceNumber(in: entry),
                  seq > 0 else { continue }
            out[source] = seq
        }
        return out
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

    enum BurstLoaderError: Error {
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
            throw BurstLoaderError.launchFailed(error.localizedDescription)
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            throw BurstLoaderError.nonZeroExit(process.terminationStatus,
                                               String(data: errData, encoding: .utf8) ?? "")
        }
        return stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    }
}
