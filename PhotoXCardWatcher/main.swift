import AppKit
import Foundation
import os
import UserNotifications

private let log = Logger(subsystem: "dev.frostman.PhotoX.CardWatcher", category: "watcher")

/// PhotoX background card watcher.
///
/// Tiny long-lived helper registered as a LaunchAgent via
/// `SMAppService` from the main PhotoX app's Settings. Subscribes to
/// `NSWorkspace.didMountNotification`, and when a mounted volume
/// looks like a camera card (has a `DCIM/` directory), posts a
/// user notification with an "Open in PhotoX" action that routes
/// back to the main app via the `photox://` URL scheme.
///
/// Design constraints (per the plan):
/// - Single mount-event observer, no polling, no directory scans.
/// - One `stat` call per mount (DCIM existence check).
/// - All identity (LaunchAgent label, parent bundle id, URL scheme)
///   comes from build settings baked into the helper's Info.plist
///   so the source code is identical across configurations.
///
/// The helper runs as a real `NSApplication` (LSUIElement /
/// activation policy `.accessory` — no Dock icon, no Cmd-Tab
/// entry, but a full AppKit event loop). A bare
/// `RunLoop.main.run()` was used originally; it gave us a
/// working observer but no way to respond to AppKit's
/// activation requests. macOS's notification system activates
/// the posting bundle on click, and without an `NSApplication`
/// to respond, LaunchServices times out with
/// "PhotoXCardWatcher is not responding" and the click never
/// reaches our `UNUserNotificationCenterDelegate.didReceive`.

// MARK: - Configuration

/// URL scheme the parent app registers. We open
/// `<scheme>://card?path=…` and macOS routes the request to the
/// matching app.
private let parentURLScheme: String = {
    Bundle.main.object(forInfoDictionaryKey: "PhotoXURLScheme") as? String
        ?? "photox"
}()

private let notificationCategoryID = "PhotoXCardMount"
private let notificationActionID = "PhotoXOpenInApp"
private let userInfoPathKey = "cardPath"

// MARK: - UN delegate

final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    // Show the notification banner even when the helper is the
    // foreground process — without this, the system suppresses
    // banners for the app that posted them.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        defer { completionHandler() }
        // Both the explicit "Open in PhotoX" action AND a plain
        // click on the notification body should open the parent
        // app on the card.
        let identifier = response.actionIdentifier
        guard identifier == notificationActionID
                || identifier == UNNotificationDefaultActionIdentifier,
              let path = response.notification.request.content.userInfo[userInfoPathKey] as? String
        else { return }
        openParent(withCardPath: path)
    }
}

// MARK: - Helpers

private func openParent(withCardPath path: String) {
    var components = URLComponents()
    components.scheme = parentURLScheme
    components.host = "card"
    components.queryItems = [URLQueryItem(name: "path", value: path)]
    guard let url = components.url else { return }
    NSWorkspace.shared.open(url)
}

/// Returns true if the volume looks like a camera card —
/// the only signal we use is presence of a `DCIM/` directory at
/// the volume root. One `stat` call. Matches the spirit of
/// PhotoX's in-app `VolumeScanner`, which uses DCIM presence
/// as the actual card signal (it deliberately doesn't filter on
/// `volumeIsRemovable` because USB readers report as fixed
/// media).
///
/// Keep in sync with `PhotoX/Shoot/VolumeWatcher.swift`.
private func isCameraCard(_ volume: URL) -> Bool {
    let dcim = volume.appendingPathComponent("DCIM")
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: dcim.path, isDirectory: &isDir)
        && isDir.boolValue
}

/// Returns every DCIM-convention shoot subfolder
/// (`100MSDCF`, `100PHOTOX`, …) inside the volume's `DCIM/`
/// directory, sorted by name. Empty when none qualify. The
/// notification's `cardPath` needs to point at one of these
/// subfolders rather than DCIM itself — PhotoX's
/// `ShootScanner` looks for ARW + HIF/JPG pairs in the
/// *immediate* directory, not recursively, so a DCIM-root
/// path would land with an empty shoot error.
///
/// Keep the convention check in sync with
/// `VolumeScanner.isDCIMConventionName` (≥ 3 chars and the
/// first 3 are digits).
private func shootFolders(in volume: URL) -> [URL] {
    let dcim = volume.appendingPathComponent("DCIM")
    guard let subs = try? FileManager.default.contentsOfDirectory(
        at: dcim,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
    ) else { return [] }
    return subs
        .filter { url in
            let name = url.lastPathComponent
            guard name.count >= 3 else { return false }
            return name.prefix(3).allSatisfy { $0.isNumber }
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
}

private func notify(cardPath: String, volumeName: String, shootName: String) {
    let content = UNMutableNotificationContent()
    content.title = "PhotoX — card detected"
    // `<volume> / <shoot>` disambiguates stacked banners
    // when a card has more than one shoot folder, which
    // macOS groups under PhotoX automatically.
    content.body = "\(volumeName) / \(shootName)"
    content.userInfo = [userInfoPathKey: cardPath]
    content.categoryIdentifier = notificationCategoryID
    content.sound = .default

    let request = UNNotificationRequest(
        identifier: UUID().uuidString,
        content: content,
        trigger: nil  // deliver immediately
    )
    UNUserNotificationCenter.current().add(request) { error in
        if let error {
            log.error("notification add failed: \(error.localizedDescription, privacy: .public) — domain=\((error as NSError).domain, privacy: .public) code=\((error as NSError).code, privacy: .public)")
        } else {
            log.info("notification add ok for \(volumeName, privacy: .public) / \(shootName, privacy: .public)")
        }
    }
}

// MARK: - App delegate

/// Owns the helper's lifetime: notification center + workspace
/// observer setup happens in `applicationDidFinishLaunching` so
/// it runs on the live NSApp event loop. Closure-captured state
/// (the dedup set) lives here too so observer closures can
/// reach it without leaking file-scope mutable globals.
final class HelperAppDelegate: NSObject, NSApplicationDelegate {
    private let notifDelegate = NotificationDelegate()

    /// Per-volume cooldown set. macOS occasionally delivers
    /// `didMountNotification` twice in quick succession for
    /// the same volume (especially for DMGs), which would
    /// otherwise post two banners for one card insert.
    /// Tracking the URL for a short cooldown after a
    /// notification, plus removing the entry on unmount,
    /// dedups the duplicate without missing legit
    /// eject/remount cycles. Observer callbacks all run on
    /// `queue: .main`, so this set is already serialised.
    private var recentlyNotified: Set<URL> = []
    private let recentlyNotifiedCooldown: DispatchTimeInterval = .seconds(3)

    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = UNUserNotificationCenter.current()
        center.delegate = notifDelegate

        // Helper has its own bundle id (parent's +
        // ".CardWatcher"), so notification permission granted
        // to the parent app doesn't cover us — we need to
        // request authorization in our own process. Triggers
        // the system prompt the first time the helper runs
        // after the user toggles it on in Settings, then
        // becomes a no-op on every subsequent launch.
        let version = (Bundle.main.object(forInfoDictionaryKey: "GitDescribe") as? String) ?? "unknown"
        log.info("startup. version=\(version, privacy: .public) URL scheme=\(parentURLScheme, privacy: .public)")
        center.getNotificationSettings { settings in
            log.info("current auth status = \(settings.authorizationStatus.rawValue, privacy: .public)")
        }
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                log.error("auth request failed: \(error.localizedDescription, privacy: .public)")
            } else {
                log.info("auth granted=\(granted, privacy: .public)")
            }
        }

        let action = UNNotificationAction(
            identifier: notificationActionID,
            title: "Open in PhotoX",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: notificationCategoryID,
            actions: [action],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])

        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] notif in
            self?.handleMount(notif)
        }
        // Unmount clears the cooldown slot immediately so a
        // deliberate eject + remount within the 3 s window
        // still produces a fresh notification. The dedup only
        // needs to suppress duplicates from the SAME mount
        // event.
        nc.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil,
            queue: .main
        ) { [weak self] notif in
            self?.handleUnmount(notif)
        }
    }

    private func handleMount(_ notif: Notification) {
        guard let volume = notif.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else {
            log.info("mount event with no volumeURL — skipping")
            return
        }
        log.info("mount event: \(volume.path, privacy: .public)")
        // Skip non-card volumes with one stat call. The vast
        // majority of mounts (system disks, Time Machine, app
        // disk images) won't have DCIM/ so this short-circuits
        // fast.
        guard isCameraCard(volume) else {
            log.info("not a card (no DCIM/) — skipping")
            return
        }
        if recentlyNotified.contains(volume) {
            log.info("duplicate mount within cooldown — skipping \(volume.path, privacy: .public)")
            return
        }
        recentlyNotified.insert(volume)
        DispatchQueue.main.asyncAfter(deadline: .now() + recentlyNotifiedCooldown) { [weak self] in
            self?.recentlyNotified.remove(volume)
        }
        // PhotoX's ShootScanner looks for image pairs in
        // the immediate folder, not recursively. The card's
        // actual shoots live one level below DCIM/ in
        // 100XXXXX-style subfolders — one notification per
        // shoot folder mirrors what the in-app Open tab's
        // Cards section lists, so a multi-shoot card gives
        // the user a direct entry point to each one.
        let folders = shootFolders(in: volume)
        guard !folders.isEmpty else {
            log.warning("DCIM exists but no 100XXXXX subfolders — no notifications posted")
            return
        }
        let volumeName = volume.lastPathComponent
        for folder in folders {
            log.info("delivering notification for \(folder.path, privacy: .public)")
            notify(cardPath: folder.path, volumeName: volumeName, shootName: folder.lastPathComponent)
        }
    }

    private func handleUnmount(_ notif: Notification) {
        guard let volume = notif.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
        if recentlyNotified.remove(volume) != nil {
            log.info("unmount cleared cooldown for \(volume.path, privacy: .public)")
        }
    }
}

// MARK: - Entry point

let appDelegate = HelperAppDelegate()
let app = NSApplication.shared
app.delegate = appDelegate
// `.accessory` mirrors the Info.plist `LSUIElement` flag at
// runtime — no Dock icon, no Cmd-Tab entry, but a full AppKit
// event loop so the helper responds to activation requests
// from the notification system (clicking the notification
// would otherwise time out with a Finder "not responding"
// alert).
app.setActivationPolicy(.accessory)
app.run()
