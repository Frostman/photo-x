import Foundation
import ServiceManagement
import os

/// Authoritative view of the background `PhotoXCardWatcher`
/// helper.
///
/// `SMAppService.status == .enabled` only reports whether the
/// LaunchAgent is *registered* with launchd. It says nothing
/// about whether the helper process is actually running — the
/// service can be `.enabled` while launchd has SIGKILL'd it on
/// every spawn attempt (a stale BTM/LWCR after the helper
/// binary's code-signing identity changed across rebuilds, for
/// example). For Settings UI and the kickstart-on-launch path
/// we need a live answer, so this type combines
/// `SMAppService.status` with a `launchctl print` against the
/// GUI-session domain to read both the live PID and the last
/// spawn exit code.
///
/// Coordination notes:
/// - Every method is async and runs `launchctl` off-main, so
///   neither the Settings poll nor the Restart button blocks
///   the UI.
/// - Bootstrap-at-launch runs at most ONCE per process. After
///   the first attempt, subsequent calls are no-ops (helper
///   binary won't change mid-process; auto-retrying a stuck
///   BTM state would just spam launchd's `runs` counter
///   without ever fixing it). User-initiated `manualRestart()`
///   bypasses this gate.
/// - An internal serializer prevents the launch bootstrap and
///   a Settings Restart click from racing on `unregister()` /
///   `register()`.
enum CardWatcherSupervisor {
    enum LiveStatus: Equatable, CustomStringConvertible {
        /// Registered AND a running process exists.
        case running(pid: pid_t)
        /// Registered with launchd but no live process — either
        /// launchd is mid-spawn, or KeepAlive is throttling
        /// after a fast exit. Distinct from `.spawnFailed`
        /// because the cause might be transient.
        case registeredNotRunning
        /// launchd's `last exit code = N` is non-zero — most
        /// commonly 78 (EX_CONFIG) when BTM's cached LWCR
        /// no longer matches the helper binary's code-signing
        /// identity and the only fix is the user toggling the
        /// helper off+on in System Settings → Login Items.
        /// Surfaced in the UI with a button that opens that
        /// pane directly.
        case spawnFailed(exitCode: Int32)
        /// Not registered with SMAppService at all.
        case notRegistered
        /// Registered but the user hasn't approved it under
        /// System Settings → Login Items yet.
        case requiresApproval
        case unknown

        var description: String {
            switch self {
            case .running(let pid): return "running(pid=\(pid))"
            case .registeredNotRunning: return "registeredNotRunning"
            case .spawnFailed(let code): return "spawnFailed(exit=\(code))"
            case .notRegistered: return "notRegistered"
            case .requiresApproval: return "requiresApproval"
            case .unknown: return "unknown"
            }
        }
    }

    /// LaunchAgent plist filename (same in every config — the
    /// post-compile script substitutes per-config build settings
    /// into its contents). Keep in sync with the filename copied
    /// into `Contents/Library/LaunchAgents/` by project.yml.
    static let plistName = "CardWatcher.plist"

    private static let log = Logger(subsystem: "dev.frostman.PhotoX", category: "watcher")

    /// Serializes bootstrap attempts AND tracks whether the
    /// once-per-session auto-bootstrap has already run.
    private actor Gate {
        private var hasAutoRun = false
        private var inFlight = false

        /// Returns true if the caller should proceed with
        /// bootstrap work. `forceManual=true` bypasses the
        /// once-per-session gate (used by the Settings Restart
        /// button) but still respects the in-flight lock.
        func tryEnter(forceManual: Bool) -> Bool {
            if inFlight { return false }
            if !forceManual && hasAutoRun { return false }
            inFlight = true
            return true
        }

        func leave() {
            hasAutoRun = true
            inFlight = false
        }
    }

    private static let gate = Gate()

    // MARK: - Public API

    /// Combine `SMAppService.status` with a single
    /// `launchctl print` to derive the live status — including
    /// the last spawn exit code so the UI can distinguish a
    /// transient "starting" state from a hard "macOS blocked
    /// the helper" state.
    static func liveStatus() async -> LiveStatus {
        let smStatus = SMAppService.agent(plistName: plistName).status
        switch smStatus {
        case .notRegistered, .notFound:
            return .notRegistered
        case .requiresApproval:
            return .requiresApproval
        case .enabled:
            return await launchdLiveStatus()
        @unknown default:
            return .unknown
        }
    }

    /// Auto-bootstrap, called from `PhotoXApp.bootstrap` once
    /// per process. Skips on second+ calls within the same
    /// session AND when another bootstrap is currently in
    /// flight. The user-facing Restart button uses
    /// `manualRestart()` instead and bypasses the once-per-
    /// session gate.
    ///
    /// Returns the final live status after the bootstrap
    /// completes (or the current one when the gate skipped
    /// our entry). Callers use this to surface unhealthy
    /// outcomes — e.g. PhotoXApp pops an alert when the
    /// helper failed to spawn and only a manual Login-Items
    /// reset will recover it.
    @discardableResult
    static func bootstrapAtLaunch() async -> LiveStatus {
        await runBootstrap(forceManual: false)
    }

    /// User-initiated restart from Settings. Bypasses the
    /// once-per-session gate, but still serializes against any
    /// in-flight bootstrap to avoid two parallel
    /// unregister/register races on SMAppService.
    @discardableResult
    static func manualRestart() async -> LiveStatus {
        await runBootstrap(forceManual: true)
    }

    // MARK: - Bootstrap pipeline

    private static func runBootstrap(forceManual: Bool) async -> LiveStatus {
        guard await gate.tryEnter(forceManual: forceManual) else {
            log.info("bootstrap: skipped (\(forceManual ? "in flight" : "already attempted this session", privacy: .public))")
            return await liveStatus()
        }
        defer { Task { await gate.leave() } }

        let status = await liveStatus()
        log.info("bootstrap: status=\(status.description, privacy: .public)")
        switch status {
        case .notRegistered, .requiresApproval, .unknown:
            // Nothing actionable — user either disabled the
            // helper, hasn't approved it yet, or SM returned
            // a state we don't understand. Still sweep
            // orphans because a process might be alive from
            // a previous registered state.
            cleanupOrphanHelpers(canonicalPID: nil)
            return status
        case .spawnFailed(let code):
            // launchd has already SIGKILL'd the helper on a
            // previous spawn (typically EX_CONFIG / 78 — a
            // BTM/LWCR mismatch from a binary rebuild). The
            // SMAppService API can NOT clear BTM's cached
            // launch constraint; only user-facing System
            // Settings → Login Items can. Don't retry; the
            // UI surfaces a fix-it button instead. But STILL
            // sweep orphans — an earlier-registered helper
            // might be alive even though launchd can no
            // longer spawn a fresh one.
            log.error("bootstrap: spawn previously failed with exit \(code, privacy: .public); not retrying (BTM stuck — user fix required via Login Items)")
            cleanupOrphanHelpers(canonicalPID: nil)
            return status
        case .running, .registeredNotRunning:
            await kickstartAndVerify(allowRecovery: true)
        }

        // Re-read so callers see the post-kickstart /
        // post-recovery result rather than the pre-bootstrap
        // one.
        let finalStatus = await liveStatus()

        // Now sweep orphans against the PID launchd currently
        // owns. Catches two cases the older path-only scan
        // missed:
        //   1. Helpers at outdated paths (older layouts).
        //   2. **Duplicates at the canonical path** — e.g.
        //      an earlier-launched helper whose kickstart -k
        //      kill failed (BTM/LWCR breakage can stall the
        //      kill) while the recovery path spawned a fresh
        //      sibling. Both live at the same path but only
        //      one is the one launchd actually tracks; the
        //      other posts ghost notifications.
        if case .running(let pid) = finalStatus {
            cleanupOrphanHelpers(canonicalPID: pid)
        } else {
            // No live PID to anchor on — fall back to
            // path-based, which still kills the obvious
            // outdated-layout orphans.
            cleanupOrphanHelpers(canonicalPID: nil)
        }

        return finalStatus
    }

    /// Kickstart the helper, then verify it actually came alive.
    /// If launchctl-kickstart exits non-zero (job missing from
    /// launchd) OR exits zero but no PID materializes (launchd
    /// silently refused to spawn — usually a stale BTM /
    /// launch-constraint mismatch left over from a previous
    /// helper binary), trigger the re-register recovery path
    /// exactly once.
    private static func kickstartAndVerify(allowRecovery: Bool) async {
        let target = launchdTarget
        // `-k` kills the running instance (if any) and starts a
        // new one. If nothing is running, `-k` is a no-op and
        // kickstart just starts the service.
        let result = await runLaunchctl(["kickstart", "-k", target])
        log.info("kickstart -k \(target, privacy: .public) → exit \(result.status, privacy: .public), output: \(result.output, privacy: .public)")

        // launchd's spawn is asynchronous — even when kickstart
        // returns 0, the helper might still be in flight. Give
        // it a beat before declaring it dead.
        try? await Task.sleep(for: .milliseconds(300))

        let state = await launchdLiveStatus()
        switch state {
        case .running(let pid):
            log.info("post-bootstrap helper pid=\(pid, privacy: .public)")
        case .spawnFailed(let code):
            log.error("post-bootstrap: spawn failed with exit \(code, privacy: .public) — BTM/LWCR mismatch; user must reset via Login Items")
        case .registeredNotRunning:
            if allowRecovery {
                log.warning("post-bootstrap: not running, trying re-register recovery (one shot)")
                await recoverByReregistering()
            } else {
                log.error("post-recovery: helper STILL not running, giving up")
            }
        case .notRegistered, .requiresApproval, .unknown:
            log.warning("post-bootstrap: unexpected status \(state.description, privacy: .public)")
        }
    }

    /// Drop and re-add the SMAppService registration to push
    /// launchd's BTM record back into sync. Only effective when
    /// the BTM cache hasn't fully poisoned (LWCR mismatches
    /// from changed code-signing identities aren't fixed by
    /// this — they need the user to flip the helper toggle in
    /// System Settings → Login Items).
    private static func recoverByReregistering() async {
        log.info("recovery: re-registering helper with SMAppService")
        let service = SMAppService.agent(plistName: plistName)
        do {
            try await service.unregister()
            log.info("recovery: unregister ok")
        } catch {
            log.error("recovery: unregister failed: \(error.localizedDescription, privacy: .public)")
        }
        do {
            try service.register()
            log.info("recovery: register ok")
        } catch {
            log.error("recovery: register failed: \(error.localizedDescription, privacy: .public)")
        }
        // Small settling delay so launchd processes the new
        // registration before we try to start the job.
        try? await Task.sleep(for: .milliseconds(300))
        await kickstartAndVerify(allowRecovery: false)
    }

    // MARK: - launchd state parsing

    /// Parse `launchctl print <target>` once to derive both
    /// the live PID and the last spawn exit code in a single
    /// subprocess call. Replaces the older runningPID-only
    /// path; both `liveStatus` and `kickstartAndVerify` route
    /// through this so we never miss a `.spawnFailed`.
    private static func launchdLiveStatus() async -> LiveStatus {
        let result = await runLaunchctl(["print", launchdTarget])
        guard result.status == 0 else {
            // launchd doesn't know about the service — fall
            // back to "registered but not yet loaded" so the
            // caller can try the recovery path. (`liveStatus`
            // never calls this when SM is .notRegistered, so a
            // missing job here genuinely means a desync.)
            return .registeredNotRunning
        }
        var pid: pid_t? = nil
        var exitCode: Int32? = nil
        for line in result.output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("pid = ") {
                let s = trimmed.dropFirst("pid = ".count)
                                .trimmingCharacters(in: .whitespaces)
                pid = pid_t(s)
            } else if trimmed.hasPrefix("last exit code = ") {
                // Format like "last exit code = 78: EX_CONFIG"
                // or "last exit code = 0" — grab leading
                // integer (allow minus for signal-coded
                // negatives though launchd doesn't usually
                // print those here).
                let s = trimmed.dropFirst("last exit code = ".count)
                let codeStr = s.prefix(while: { $0.isNumber || $0 == "-" })
                exitCode = Int32(codeStr)
            }
        }
        if let pid {
            return .running(pid: pid)
        }
        if let code = exitCode, code != 0 {
            return .spawnFailed(exitCode: code)
        }
        return .registeredNotRunning
    }

    // MARK: - Orphan cleanup

    /// Absolute path of the helper binary this app would
    /// spawn — derived from `Bundle.main.bundleURL` so it
    /// tracks the current bundle (DerivedData rebuild,
    /// /Applications install, etc.) without ever being
    /// hard-coded.
    private static var canonicalHelperPath: String {
        Bundle.main.bundleURL
            .appendingPathComponent(
                "Contents/Library/LoginItems/PhotoXCardWatcher.app/Contents/MacOS/PhotoXCardWatcher")
            .path
    }

    /// SIGTERM any `PhotoXCardWatcher` process whose binary
    /// lives **inside this app bundle** but isn't the one
    /// launchd currently owns.
    ///
    /// - When `canonicalPID` is supplied (post-kickstart),
    ///   ANY in-bundle helper with a different PID is an
    ///   orphan — even those at the canonical path. This is
    ///   how we catch "ghost" duplicates: an earlier helper
    ///   whose kickstart-kill failed (BTM/LWCR breakage can
    ///   stall the kill) while recovery spawned a fresh
    ///   sibling at the same path.
    /// - When `canonicalPID` is nil (pre-kickstart fallback
    ///   for spawnFailed / unregistered states where launchd
    ///   doesn't have an authoritative PID), we still kill
    ///   anything outside the canonical path. Less precise,
    ///   but enough to clear outdated-layout orphans.
    ///
    /// The bundle-prefix scope keeps dev / prod isolated:
    /// the dev build's bundle path is its DerivedData `.app`,
    /// the prod build's is `/Applications/PhotoX.app` —
    /// neither covers the other, so a dev cleanup never
    /// SIGTERMs prod's helper and vice versa.
    ///
    /// Implementation: uses `proc_listpids` + `proc_pidpath`
    /// (libproc) rather than spawning `ps`. Faster, no
    /// parsing, harder to spoof.
    private static func cleanupOrphanHelpers(canonicalPID: pid_t?) {
        let canonical = canonicalHelperPath
        // `<bundle path>/` — the trailing slash prevents
        // accidentally matching a sibling app whose path
        // happens to share a prefix (e.g. `PhotoX.app` vs
        // `PhotoX-debug.app`).
        let myBundlePrefix = Bundle.main.bundleURL.path + "/"
        let myPID = getpid()

        var pids = [pid_t](repeating: 0, count: 4096)
        let bufBytes = Int32(pids.count * MemoryLayout<pid_t>.size)
        let bytes = pids.withUnsafeMutableBufferPointer { buf -> Int32 in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, buf.baseAddress, bufBytes)
        }
        guard bytes > 0 else {
            log.warning("orphan-scan: proc_listpids returned \(bytes, privacy: .public), skipping")
            return
        }
        let count = Int(bytes) / MemoryLayout<pid_t>.size

        var orphans: [(pid: pid_t, path: String)] = []
        // libproc's PROC_PIDPATHINFO_MAXSIZE (= 4 * MAXPATHLEN
        // = 4096) isn't bridged into Swift; hard-code it.
        var pathBuf = [CChar](repeating: 0, count: 4096)
        for pid in pids.prefix(count) {
            guard pid > 0, pid != myPID else { continue }
            let n = pathBuf.withUnsafeMutableBufferPointer { buf -> Int32 in
                proc_pidpath(pid, buf.baseAddress, UInt32(buf.count))
            }
            guard n > 0 else { continue }
            let path = String(cString: pathBuf)
            guard path.hasSuffix("/PhotoXCardWatcher") else { continue }
            // **Crucial scoping**: only orphans inside THIS
            // app's bundle. Keeps dev / prod isolated.
            guard path.hasPrefix(myBundlePrefix) else { continue }

            if let canonicalPID {
                // Authoritative PID known — anything else is
                // an orphan, regardless of where its binary
                // lives.
                if pid == canonicalPID { continue }
            } else {
                // No authoritative PID — only kill obvious
                // outdated-path orphans, leave canonical-path
                // processes alone (we can't tell good from
                // ghost without knowing who launchd owns).
                if path == canonical { continue }
            }
            orphans.append((pid, path))
        }

        guard !orphans.isEmpty else {
            let anchor = canonicalPID.map { "pid=\($0)" } ?? "path=\(canonical)"
            log.info("orphan-scan: none found (anchor=\(anchor, privacy: .public))")
            return
        }
        log.warning("orphan-scan: terminating \(orphans.count, privacy: .public) orphan helper(s)")
        for orphan in orphans {
            log.warning("orphan-scan: SIGTERM pid=\(orphan.pid, privacy: .public) path=\(orphan.path, privacy: .public)")
            kill(orphan.pid, SIGTERM)
        }
    }

    /// `gui/<uid>/<label>` — the GUI-session launchd domain.
    /// SMAppService agents register here; `user/<uid>` is the
    /// wrong domain and returns exit 113 ("Could not find
    /// service").
    private static var launchdTarget: String {
        let parent = Bundle.main.bundleIdentifier ?? "dev.frostman.PhotoX"
        return "gui/\(getuid())/\(parent).CardWatcher"
    }

    /// Run `/bin/launchctl <args>` on a background queue so
    /// the blocking `Process.waitUntilExit()` never stalls
    /// the caller's actor (typically MainActor for the
    /// Settings poll and the Restart button).
    private static func runLaunchctl(_ args: [String]) async -> (status: Int32, output: String) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let task = Process()
                task.launchPath = "/bin/launchctl"
                task.arguments = args
                let pipe = Pipe()
                task.standardOutput = pipe
                task.standardError = pipe
                do {
                    try task.run()
                    task.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let out = String(data: data, encoding: .utf8) ?? ""
                    continuation.resume(returning: (task.terminationStatus, out))
                } catch {
                    continuation.resume(returning: (-1, "exec error: \(error.localizedDescription)"))
                }
            }
        }
    }
}
