import Foundation
import IndexingCore

/// `photox diagnose <shoot-folder>` — loads the sidecar from
/// `<shoot-folder>/.photox-index.plist`, scans the folder, and for
/// every entry computes the live fingerprint and compares it to
/// the sidecar's stored fingerprint. Prints the first N mismatches
/// with size + mtime deltas so we can see exactly why a sidecar
/// isn't matching live files.
///
/// Diagnostic only — doesn't write anything.
enum DiagnoseCommand {

    struct Args {
        var shootFolder: URL
        var maxPrint: Int = 10
    }

    static func usage() -> Never {
        FileHandle.standardError.write(Data("""
        Usage: photox diagnose <shoot-folder> [--max N]

          Compares the sidecar plist's stored fingerprints to live
          fingerprints computed from the same files. Prints a
          summary (matched / mismatched / sidecar-only / live-only)
          plus the first N mismatches with size and mtime deltas
          so cross-platform fingerprint drift is visible.

          --max N    Max mismatches to print in detail. Default 10.

        """.utf8))
        exit(2)
    }

    static func parseArgs(_ argv: [String]) -> Args {
        guard !argv.isEmpty else { usage() }
        var positional: [String] = []
        var maxPrint = 10
        var i = 0
        while i < argv.count {
            let arg = argv[i]
            switch arg {
            case "-h", "--help": usage()
            case "--max":
                i += 1
                guard i < argv.count, let n = Int(argv[i]), n >= 0 else { usage() }
                maxPrint = n
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
        return Args(shootFolder: folder.standardizedFileURL, maxPrint: maxPrint)
    }

    static func run(args argv: [String]) {
        let args = parseArgs(argv)

        guard let sidecar = SidecarReader.load(at: args.shootFolder) else {
            FileHandle.standardError.write(Data("""
                No sidecar at \(SidecarFile.url(in: args.shootFolder).path)
                (or it failed to decode / has wrong schema version)
                """.utf8))
            exit(1)
        }
        FileHandle.standardError.write(Data(
            "Sidecar: \(sidecar.entries.count) entries · indexer \(sidecar.indexerVersion)\n".utf8))

        let shoot = ShootScanner.scan(folder: args.shootFolder)
        FileHandle.standardError.write(Data(
            "Folder: \(shoot.entries.count) entries scanned\n\n".utf8))

        var matched = 0
        var mismatched: [(stem: String, sidecarFp: IndexFingerprint, liveFp: IndexFingerprint)] = []
        var sidecarStems = Set(sidecar.entries.keys)
        var liveOnly: [String] = []

        for entry in shoot.entries {
            // previewURL matches what both the Linux CLI's
            // indexer and the macOS app's prefetch use for
            // fingerprinting — keep this aligned or the diagnose
            // becomes a false negative.
            sidecarStems.remove(entry.stem)
            guard let sidecarEntry = sidecar.entries[entry.stem] else {
                liveOnly.append(entry.stem)
                continue
            }
            do {
                let liveFp = try IndexingCoordinator.fingerprint(of: entry.previewURL)
                if sidecarEntry.fingerprint == liveFp {
                    matched += 1
                } else {
                    mismatched.append((entry.stem, sidecarEntry.fingerprint, liveFp))
                }
            } catch {
                FileHandle.standardError.write(Data("stat failed for \(entry.stem): \(error)\n".utf8))
            }
        }
        let sidecarOnly = sidecarStems

        // Summary
        let summary = """
        ── Summary ────────────────────────────────────────
          matched:        \(matched)
          mismatched:     \(mismatched.count)
          sidecar-only:   \(sidecarOnly.count)  (in sidecar but not on disk)
          live-only:      \(liveOnly.count)     (on disk but not in sidecar)
        ── Tolerance ──────────────────────────────────────
          IndexFingerprint.== allows |Δmtime| ≤ \(IndexFingerprint.mtimeToleranceNanos) ns
          (= \(Double(IndexFingerprint.mtimeToleranceNanos) / 1_000_000_000) s)

        """
        FileHandle.standardError.write(Data(summary.utf8))

        // Mismatch detail
        if !mismatched.isEmpty {
            FileHandle.standardError.write(Data("── First \(min(args.maxPrint, mismatched.count)) mismatches ──\n".utf8))
            for m in mismatched.prefix(args.maxPrint) {
                let sizeMatch = m.sidecarFp.size == m.liveFp.size
                let mtimeDelta = abs(m.sidecarFp.mtimeNanos &- m.liveFp.mtimeNanos)
                let mtimeDeltaSec = Double(mtimeDelta) / 1_000_000_000
                let line = """

                \(m.stem)
                  size:   sidecar=\(m.sidecarFp.size)  live=\(m.liveFp.size)  match=\(sizeMatch)
                  mtime:  sidecar=\(m.sidecarFp.mtimeNanos)
                          live=   \(m.liveFp.mtimeNanos)
                          Δ=\(mtimeDelta) ns  (\(String(format: "%.6f", mtimeDeltaSec)) s)

                """
                FileHandle.standardError.write(Data(line.utf8))
            }
        }
    }
}
