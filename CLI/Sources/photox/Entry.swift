import Foundation
import IndexingCore

@main
struct Main {
    /// Resolved at module init from $PHOTOX_VERSION (set by the
    /// Justfile build target), falling back to "dev". Surfaced via
    /// `--version` and embedded into each sidecar's indexerVersion
    /// field so the macOS app's popover shows a recognisable stamp.
    static let toolVersion: String = {
        if let v = ProcessInfo.processInfo.environment["PHOTOX_VERSION"],
           !v.isEmpty {
            return v
        }
        return "dev"
    }()

    static func topLevelUsage() -> Never {
        FileHandle.standardError.write(Data("""
        photox — PhotoX command-line tools (\(toolVersion))

        Usage: photox <command> [args...]

        Commands:
          index <shoot-folder>     Scan a shoot folder and write .photox-index.plist
                                   (the sidecar the macOS app prefer-loads on shoot
                                   open). Run `photox index --help` for options.

        Global flags:
          --version                Print version and exit.
          -h, --help               Print this message and exit.

        """.utf8))
        exit(2)
    }

    static func main() async {
        let argv = CommandLine.arguments
        guard argv.count >= 2 else { topLevelUsage() }
        let cmd = argv[1]
        let rest = Array(argv.dropFirst(2))
        switch cmd {
        case "index":
            await IndexCommand.run(args: rest)
        case "--version":
            FileHandle.standardOutput.write(Data("\(toolVersion)\n".utf8))
            exit(0)
        case "-h", "--help":
            topLevelUsage()
        default:
            FileHandle.standardError.write(Data("unknown command: \(cmd)\n\n".utf8))
            topLevelUsage()
        }
    }
}
