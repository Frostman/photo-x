import AppKit
import Foundation
import Observation

/// Watches for removable media (SD / CFExpress cards) while the user is
/// on the starter screen. When a card is plugged in or unplugged,
/// re-scans `/Volumes/*` for DCIM-style shoot folders and publishes the
/// list so `ContentView` can render a "Cards" section between Favorites
/// and Recents.
///
/// Lifecycle is bracketed by `emptyState.onAppear` / `.onDisappear` so
/// we only consume notification + IO budget while it can matter. The
/// instance survives across starter ↔ shoot transitions; `start`/`stop`
/// are idempotent.
@MainActor
@Observable
final class VolumeWatcher {
    /// Detected DCIM-style folders that contain at least one ARW + HIF
    /// pair. One entry per qualifying subfolder per card, sorted
    /// alphabetically so the UI order is stable across re-scans.
    private(set) var cardFolders: [String] = []

    private var observers: [NSObjectProtocol] = []
    private var scanTask: Task<Void, Never>?

    func start() {
        guard observers.isEmpty else { return }
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification,
                     NSWorkspace.didUnmountNotification] {
            // The block closure is non-isolated (Swift's strict
            // concurrency can't see that queue: .main is MainActor),
            // so hop to MainActor explicitly to call our actor-isolated
            // scan(). Cost is one runloop tick — irrelevant here.
            let token = nc.addObserver(forName: name,
                                       object: nil,
                                       queue: .main) { [weak self] _ in
                Task { @MainActor in self?.scan() }
            }
            observers.append(token)
        }
        scan()  // initial sweep picks up already-mounted cards
    }

    func stop() {
        let nc = NSWorkspace.shared.notificationCenter
        observers.forEach { nc.removeObserver($0) }
        observers.removeAll()
        scanTask?.cancel()
        scanTask = nil
        cardFolders.removeAll()
    }

    /// Re-scan. Cancels any in-flight scan so a quick mount → unmount →
    /// mount can't pile up stale results — the latest scan wins.
    private func scan() {
        scanTask?.cancel()
        scanTask = Task.detached(priority: .utility) { [weak self] in
            let found = VolumeScanner.findCardFolders()
            #if DEBUG
            Log.app.notice("VolumeWatcher scan: \(found.count, privacy: .public) card folder(s) found")
            #endif
            await MainActor.run { [weak self] in
                guard let self else { return }
                if self.cardFolders != found {
                    self.cardFolders = found
                }
            }
        }
    }
}

/// Pure scanner — no SwiftUI / NSWorkspace state. The `findCardFolders`
/// entry point production calls with the default `/Volumes` root;
/// tests can target a temp directory tree.
enum VolumeScanner {
    /// Returns DCIM-style shoot folders across every mounted volume,
    /// alphabetically sorted. Empty on no cards / no qualifying folders.
    static func findCardFolders() -> [String] {
        findCardFolders(volumesRoot: "/Volumes")
    }

    /// DCIM presence is the actual signal — we deliberately DON'T filter
    /// on `volumeIsRemovable` / `volumeIsEjectable` because macOS reports
    /// USB SD/CFExpress readers as "Fixed" media (the reader is fixed;
    /// the card *inside* is removable). Volumes without a `DCIM/` at
    /// their root (boot disk, Time Machine backups, etc.) naturally drop
    /// out because the `contentsOfDirectory` call below returns nil.
    static func findCardFolders(volumesRoot: String) -> [String] {
        let fm = FileManager.default
        guard let volumeNames = try? fm.contentsOfDirectory(atPath: volumesRoot) else {
            return []
        }
        var out: [String] = []
        for name in volumeNames {
            let volumeURL = URL(fileURLWithPath: "\(volumesRoot)/\(name)")
            let dcimURL = volumeURL.appendingPathComponent("DCIM")
            guard let subs = try? fm.contentsOfDirectory(
                at: dcimURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            ) else { continue }
            for sub in subs where isDCIMConventionName(sub.lastPathComponent) {
                if folderHasPairedShoot(at: sub.path) {
                    out.append(sub.path)
                }
            }
        }
        return out.sorted()
    }

    /// Strict DCIM convention: name has ≥ 3 chars and the first 3 are
    /// digits. Covers `100MSDCF`, `101MSDCF`, `100ANDRO`, `100GOPRO`,
    /// `100APPLE`, etc. — anything that follows the DCIM standard.
    static func isDCIMConventionName(_ name: String) -> Bool {
        guard name.count >= 3 else { return false }
        return name.prefix(3).allSatisfy { $0.isNumber }
    }

    /// Reuses the same definition Favorites / Recents use so there's a
    /// single source of truth for "what counts as a shoot".
    private static func folderHasPairedShoot(at path: String) -> Bool {
        if case .ok(let count) = FolderStats.compute(for: path),
           count.total > 0 {
            return true
        }
        return false
    }
}
