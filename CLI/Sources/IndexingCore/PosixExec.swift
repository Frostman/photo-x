#if os(Linux)
#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// Raw fork+execve helper used in place of `Foundation.Process` on
/// Linux. swift-corelibs-foundation's Process implementation runs an
/// `access(path, X_OK)` (or equivalent) validation before
/// posix_spawn and fails with EACCES on Nix-store binaries even when
/// they're world-executable and run fine from a shell. Calling
/// execve(2) directly skips that check and uses the same kernel
/// path the shell uses, so the behaviour matches the user's
/// expectation.
///
/// Only stdout + stderr capture and exit-code retrieval are wired up
/// — that's all the batch loader needs. No stdin support (exiftool
/// reads from argv only).
public enum PosixExec {
    public struct Result: Sendable {
        public let stdout: Data
        public let stderr: Data
        public let exitCode: Int32
    }

    public enum Error: Swift.Error, CustomStringConvertible {
        case pipeFailed(errno: Int32)
        case forkFailed(errno: Int32)
        case waitFailed(errno: Int32)

        public var description: String {
            switch self {
            case .pipeFailed(let e):  return "pipe() failed (errno=\(e): \(String(cString: strerror(e))))"
            case .forkFailed(let e):  return "fork() failed (errno=\(e): \(String(cString: strerror(e))))"
            case .waitFailed(let e):  return "waitpid() failed (errno=\(e): \(String(cString: strerror(e))))"
            }
        }
    }

    /// Spawn `executable arguments...`, capture stdout + stderr, wait
    /// for completion, return the result. Inherits the parent's
    /// environment unless overridden.
    public static func run(executable: String,
                           arguments: [String],
                           environment: [String: String]? = nil) throws -> Result {
        // Two pipes — index 0 is read end, 1 is write end.
        var stdoutFds: [Int32] = [-1, -1]
        var stderrFds: [Int32] = [-1, -1]
        guard stdoutFds.withUnsafeMutableBufferPointer({ pipe($0.baseAddress) }) == 0
        else { throw Error.pipeFailed(errno: errno) }
        guard stderrFds.withUnsafeMutableBufferPointer({ pipe($0.baseAddress) }) == 0
        else {
            close(stdoutFds[0]); close(stdoutFds[1])
            throw Error.pipeFailed(errno: errno)
        }

        // Build argv and envp as C string arrays. The child's
        // execve takes ownership conceptually; we free the parent
        // copies on exit via defer. argv[0] convention is the
        // program name, so the executable path repeats there.
        let argv: [String] = [executable] + arguments
        let cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        defer { cArgs.forEach { if let p = $0 { free(p) } } }
        var argvPtrs: [UnsafeMutablePointer<CChar>?] = cArgs + [nil]

        let env = environment ?? ProcessInfo.processInfo.environment
        let envStrings = env.map { "\($0.key)=\($0.value)" }
        let cEnv: [UnsafeMutablePointer<CChar>?] = envStrings.map { strdup($0) }
        defer { cEnv.forEach { if let p = $0 { free(p) } } }
        var envPtrs: [UnsafeMutablePointer<CChar>?] = cEnv + [nil]

        let pid = fork()
        if pid < 0 {
            let err = errno
            close(stdoutFds[0]); close(stdoutFds[1])
            close(stderrFds[0]); close(stderrFds[1])
            throw Error.forkFailed(errno: err)
        }
        if pid == 0 {
            // ── Child ────────────────────────────────────────────
            // Redirect stdout + stderr to the write ends of our
            // pipes. Close all parent-inherited fds we don't need.
            _ = dup2(stdoutFds[1], 1)
            _ = dup2(stderrFds[1], 2)
            close(stdoutFds[0]); close(stdoutFds[1])
            close(stderrFds[0]); close(stderrFds[1])
            // Exec. If this returns, it failed — print errno and
            // bail with 127 (the usual "exec failed" status).
            argvPtrs.withUnsafeMutableBufferPointer { ab in
                envPtrs.withUnsafeMutableBufferPointer { eb in
                    _ = execve(executable, ab.baseAddress, eb.baseAddress)
                }
            }
            let err = errno
            let msg = "exec failed: errno=\(err) (\(String(cString: strerror(err))))\n"
            _ = msg.withCString { write(2, $0, strlen($0)) }
            _exit(127)
        }

        // ── Parent ───────────────────────────────────────────────
        // Close write ends so EOF actually arrives on our reads
        // once the child exits.
        close(stdoutFds[1])
        close(stderrFds[1])
        defer { close(stdoutFds[0]); close(stderrFds[0]) }

        // Read stdout first, then stderr. For batch exiftool runs
        // both streams together fit comfortably under the kernel
        // pipe buffer (64 KB default) so we don't need select() to
        // avoid a deadlock — the child writes everything and exits
        // before either pipe blocks.
        let stdoutData = readToEOF(fd: stdoutFds[0])
        let stderrData = readToEOF(fd: stderrFds[0])

        var status: Int32 = 0
        guard waitpid(pid, &status, 0) >= 0 else {
            throw Error.waitFailed(errno: errno)
        }
        // WEXITSTATUS: low 8 bits of the high byte.
        let exitCode: Int32 = (status & 0xff00) >> 8

        return Result(stdout: stdoutData, stderr: stderrData, exitCode: exitCode)
    }

    private static func readToEOF(fd: Int32) -> Data {
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = buf.withUnsafeMutableBufferPointer { bp -> ssize_t in
                read(fd, bp.baseAddress, bp.count)
            }
            if n <= 0 { break }
            out.append(buf, count: Int(n))
        }
        return out
    }
}
#endif
