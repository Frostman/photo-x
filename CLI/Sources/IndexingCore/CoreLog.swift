import Foundation

/// Lightweight logging shim used by IndexingCore so the same code can
/// log to os.log on macOS (when the PhotoX app routes here at startup)
/// and to stderr on Linux (the photox-indexer CLI). Callers replace
/// `notice` / `error` once at process start; defaults write to stderr.
///
/// We deliberately don't pull in swift-log here: the API surface is
/// tiny (two messages), and a dependency-free shim keeps the static
/// Linux build trivial.
public enum CoreLog {
    /// Replace at process start to route into your host logger.
    public static var notice: @Sendable (String) -> Void = { writeLine("[notice] " + $0) }
    public static var error:  @Sendable (String) -> Void = { writeLine("[error] "  + $0) }

    private static func writeLine(_ s: String) {
        FileHandle.standardError.write(Data((s + "\n").utf8))
    }
}
