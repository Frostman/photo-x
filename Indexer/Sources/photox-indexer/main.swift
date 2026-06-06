import Foundation
import IndexingCore

// MARK: - Args

struct Args {
    var shootFolder: URL
    var exifToolPath: String?
    var workers: Int?
    var quiet: Bool = false
}

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    Usage: photox-indexer <shoot-folder> [--exiftool PATH] [--workers N] [--quiet]

      Scans <shoot-folder> for ARW+HIF / ARW+JPG pairs (and standalone
      HIF/JPG), extracts EXIF + Sony AF data + embedded thumbnails,
      writes a sidecar plist (.photox-index.plist) into the folder.

      --exiftool PATH    Path to the exiftool binary (default: $PATH).
      --workers N        Parallel workers per pipeline (default: cpu count).
      --quiet            Suppress per-progress output (final summary only).

    The macOS PhotoX app prefer-loads the sidecar on shoot open and
    skips its own indexing pipelines for any entry whose fingerprint
    matches the cached one.

    """.utf8))
    exit(2)
}

func parseArgs() -> Args {
    let argv = CommandLine.arguments
    guard argv.count >= 2 else { usage() }
    var positional: [String] = []
    var exifToolPath: String?
    var workers: Int?
    var quiet = false
    var i = 1
    while i < argv.count {
        let arg = argv[i]
        switch arg {
        case "-h", "--help":
            usage()
        case "--exiftool":
            i += 1
            guard i < argv.count else { usage() }
            exifToolPath = argv[i]
        case "--workers":
            i += 1
            guard i < argv.count, let n = Int(argv[i]), n > 0 else { usage() }
            workers = n
        case "--quiet":
            quiet = true
        default:
            if arg.hasPrefix("-") { usage() }
            positional.append(arg)
        }
        i += 1
    }
    guard positional.count == 1 else { usage() }
    let folder = URL(fileURLWithPath: positional[0])
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir),
          isDir.boolValue else {
        FileHandle.standardError.write(Data("Not a directory: \(folder.path)\n".utf8))
        exit(2)
    }
    return Args(
        shootFolder: folder.standardizedFileURL,
        exifToolPath: exifToolPath,
        workers: workers,
        quiet: quiet
    )
}

// MARK: - exiftool resolution

func resolveExiftool(_ explicit: String?) -> String? {
    if let explicit, FileManager.default.isExecutableFile(atPath: explicit) {
        return explicit
    }
    // $PATH lookup via `which`.
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["which", "exiftool"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    do {
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let p = path, !p.isEmpty,
              FileManager.default.isExecutableFile(atPath: p) else { return nil }
        return p
    } catch {
        return nil
    }
}

// MARK: - Indexer version (from env, fallback "dev")

let indexerVersion: String = {
    if let v = ProcessInfo.processInfo.environment["PHOTOX_INDEXER_VERSION"],
       !v.isEmpty {
        return v
    }
    return "dev"
}()

// MARK: - Progress printer

actor ProgressPrinter {
    let total: Int
    let quiet: Bool
    var lastEmitted: Date = .distantPast

    init(total: Int, quiet: Bool) {
        self.total = total
        self.quiet = quiet
    }

    func update(_ p: IndexingCoordinator.Progress) {
        guard !quiet else { return }
        let now = Date()
        // Throttle to every 250 ms so stderr isn't spammed on a fast
        // run; emit a final tick at 100% regardless.
        let pct = (p.fingerprintsDone + p.advancedExifDone + p.basicExifAndThumbsDone)
        let cap = max(1, p.totalEntries * 3)
        let isComplete = (p.fingerprintsDone == p.totalEntries
                          && p.advancedExifDone == p.totalEntries
                          && p.basicExifAndThumbsDone == p.totalEntries)
        if !isComplete, now.timeIntervalSince(lastEmitted) < 0.25 { return }
        lastEmitted = now
        let percent = Int(Double(pct) / Double(cap) * 100)
        let line = String(
            format: "[%3d%%] fingerprint %d/%d  exiftool %d/%d  thumbs+exif %d/%d\r",
            percent,
            p.fingerprintsDone, p.totalEntries,
            p.advancedExifDone, p.totalEntries,
            p.basicExifAndThumbsDone, p.totalEntries
        )
        FileHandle.standardError.write(Data(line.utf8))
    }

    func finalize(_ summary: String) {
        FileHandle.standardError.write(Data("\n".utf8))
        FileHandle.standardError.write(Data(summary.utf8))
    }
}

// MARK: - Main

@main
struct Main {
    static func main() async {
        let args = parseArgs()

        // exiftool resolution. Empty path is allowed but warned —
        // AF / sequence number won't populate.
        if let path = resolveExiftool(args.exifToolPath) {
            ExifToolRunner.exifToolPath = path
            FileHandle.standardError.write(Data("exiftool: \(path)\n".utf8))
        } else {
            FileHandle.standardError.write(Data(
                "warning: exiftool not found — AF data + sequence number will be skipped\n".utf8))
            ExifToolRunner.exifToolPath = ""
        }

        // Quick pre-scan so the progress printer knows the total.
        let shoot = ShootScanner.scan(folder: args.shootFolder)
        guard !shoot.entries.isEmpty else {
            FileHandle.standardError.write(Data(
                "No ARW+HIF / ARW+JPG / HIF / JPG entries in \(args.shootFolder.path)\n".utf8))
            exit(1)
        }
        let printer = ProgressPrinter(total: shoot.entries.count, quiet: args.quiet)

        let workers = args.workers ?? ProcessInfo.processInfo.activeProcessorCount
        let started = Date()
        let coord = IndexingCoordinator(
            shootFolder: args.shootFolder,
            workerCount: workers,
            indexerVersion: indexerVersion,
            progress: { p in Task { await printer.update(p) } }
        )
        let sidecar = await coord.run()
        let elapsed = Date().timeIntervalSince(started)

        do {
            try SidecarWriter.write(sidecar, to: args.shootFolder)
        } catch {
            FileHandle.standardError.write(Data(
                "Failed to write sidecar: \(error)\n".utf8))
            exit(1)
        }

        let sidecarURL = SidecarFile.url(in: args.shootFolder)
        let size = (try? FileManager.default.attributesOfItem(atPath: sidecarURL.path)[.size]
                    as? NSNumber)?.int64Value ?? 0
        let withThumb = sidecar.entries.values.filter { $0.thumbnailJPEG != nil }.count
        let withAF = sidecar.entries.values.filter { $0.afData != nil }.count
        let withExif = sidecar.entries.values.filter { $0.exif != nil }.count

        await printer.finalize(String(
            format: "Indexed %d entries in %.1fs — wrote %@ (%@)\n  exif: %d  thumbs: %d  AF: %d\n",
            sidecar.entries.count, elapsed,
            sidecarURL.path, formatBytes(size),
            withExif, withThumb, withAF
        ))

        exit(0)
    }
}

func formatBytes(_ bytes: Int64) -> String {
    let units = ["B", "KB", "MB", "GB"]
    var size = Double(bytes)
    var idx = 0
    while size >= 1024, idx < units.count - 1 {
        size /= 1024; idx += 1
    }
    return String(format: "%.1f %@", size, units[idx])
}
