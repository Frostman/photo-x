import Foundation
import IndexingCore

/// `photox index <shoot-folder>` — runs the indexing coordinator
/// against one shoot folder and writes the sidecar plist alongside
/// the photos. All Sony-AF / exiftool batch failures are recoverable
/// (sidecar still gets exif + thumbs even when AF is missing).
enum IndexCommand {

    struct Args {
        var shootFolder: URL
        var exifToolPath: String?
        var workers: Int?
        var quiet: Bool = false
    }

    static func usage() -> Never {
        FileHandle.standardError.write(Data("""
        Usage: photox index <shoot-folder> [--exiftool PATH] [--workers N] [--quiet]

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

    static func parseArgs(_ argv: [String]) -> Args {
        guard !argv.isEmpty else { usage() }
        var positional: [String] = []
        var exifToolPath: String?
        var workers: Int?
        var quiet = false
        var i = 0
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

    // MARK: - exiftool probe

    enum ProbeResult {
        /// `exiftool -ver` succeeded and returned the version string.
        case ok(String)
        /// Probe failed but the path is still set so per-batch spawn
        /// can try and report real errors. Useful diagnostic to surface
        /// at startup without hiding the underlying error.
        case spawnFailed(reason: String)
        /// Tool path is empty — indexing skips exiftool batches.
        case noTool
    }

    /// Run `<exifToolPath> -ver` and report what happened. On Linux
    /// uses raw fork+execve via PosixExec to bypass
    /// swift-corelibs-foundation's broken access() check.
    static func probeExiftool() -> ProbeResult {
        if ExifToolRunner.exifToolPath.isEmpty { return .noTool }
        let path = ExifToolRunner.exifToolPath
        #if os(Linux)
        do {
            let r = try PosixExec.run(executable: path, arguments: ["-ver"])
            if r.exitCode != 0 {
                let stderr = String(data: r.stderr, encoding: .utf8) ?? ""
                return .spawnFailed(reason: "exit \(r.exitCode): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            let v = String(data: r.stdout, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
            return .ok(v)
        } catch {
            return .spawnFailed(reason: "PosixExec: \(error)")
        }
        #else
        let process = ExifToolRunner.makeProcess(arguments: ["-ver"])
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            return .spawnFailed(reason: "Process.run: \(error.localizedDescription)")
        }
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                                encoding: .utf8) ?? ""
            return .spawnFailed(
                reason: "exit \(process.terminationStatus): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
            )
        }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        let v = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
        return .ok(v)
        #endif
    }

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

    // MARK: - Run

    static func run(args argv: [String]) async {
        let args = parseArgs(argv)

        // Configure exiftool path. Explicit --exiftool wins; otherwise
        // fall through to the IndexingCore default (bundled on macOS,
        // $PATH walk on Linux). The walk happens in Swift so we don't
        // depend on `which` / `/usr/bin/env` being executable from
        // Swift Process (both fail in different ways on NixOS).
        if let explicit = args.exifToolPath {
            ExifToolRunner.exifToolPath = explicit
        }
        switch probeExiftool() {
        case .ok(let v):
            FileHandle.standardError.write(Data(
                "exiftool: \(ExifToolRunner.exifToolPath) (version \(v))\n".utf8))
        case .spawnFailed(let reason):
            // Leave exifToolPath set so the per-batch spawn surfaces
            // the real error per batch. Some hosts (NixOS we saw)
            // can't spawn the resolved binary from Swift's Process
            // even when the shell can — the per-batch failure then
            // becomes the source of truth and we stop hiding it
            // behind a startup probe.
            FileHandle.standardError.write(Data("""
                warning: exiftool probe failed (\(reason))
                  resolved path: \(ExifToolRunner.exifToolPath)
                  proceeding anyway — AF/seq batches will retry per-batch and may surface a clearer error
                  pass --exiftool /full/path/to/exiftool to override

                """.utf8))
        case .noTool:
            let pathVar = ProcessInfo.processInfo.environment["PATH"] ?? "<unset>"
            FileHandle.standardError.write(Data("""
                warning: no exiftool found — AF data + sequence number will be skipped
                  PATH searched: \(pathVar)
                  pass --exiftool /full/path/to/exiftool to override

                """.utf8))
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
            indexerVersion: Main.toolVersion,
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
