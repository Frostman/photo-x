import AppKit
import Foundation
import UserNotifications
import os

/// Thin wrapper around `UNUserNotificationCenter` for the Export feature.
/// Authorization is requested lazily on the first attempt to post.
@MainActor
enum ExportNotifications {

    private static let log = Logger(subsystem: "dev.frostman.PhotoX",
                                    category: "export")

    private static var authorizationRequested = false

    private static func requestAuthorizationIfNeeded() async -> Bool {
        if authorizationRequested {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            return settings.authorizationStatus == .authorized ||
                   settings.authorizationStatus == .provisional
        }
        authorizationRequested = true
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        )) ?? false
        return granted
    }

    /// One summary at the end of every batch — single-destination Run
    /// included. Per-destination notifications were removed: they were
    /// noisy and didn't add value once the toolbar pill / sheet show
    /// progress per row.
    static func postAllComplete(
        summaries: [(ExportSettings.Destination, ExportRunner.Summary)]
    ) {
        // Don't bother notifying if the user is already looking at PhotoX —
        // the pill and sheet show completion just as well, and a banner on
        // top of that is just noise.
        if NSApplication.shared.isActive { return }

        let totalCopied = summaries.reduce(0) { $0 + $1.1.copied }
        let totalSkipped = summaries.reduce(0) { $0 + $1.1.skipped }
        let totalDeleted = summaries.reduce(0) { $0 + $1.1.deleted }
        let errors = summaries.reduce(0) { $0 + $1.1.errors.count }

        let title = summaries.count == 1
            ? "Export to \((summaries[0].0.path as NSString).lastPathComponent) finished"
            : "Export to \(summaries.count) destinations finished"
        let body = "\(totalCopied) copied · \(totalSkipped) skipped"
            + (totalDeleted > 0 ? " · \(totalDeleted) deleted" : "")
            + (errors > 0       ? " · \(errors) errors"        : "")

        post(title: title, body: body,
             identifier: "photox.export.complete.\(UUID().uuidString)")
    }

    private static func post(title: String, body: String, identifier: String) {
        Task {
            guard await requestAuthorizationIfNeeded() else { return }
            // Re-check at submission time — the user may have brought the
            // app forward between when the export finished and when this
            // task runs.
            if NSApplication.shared.isActive { return }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            // Time-sensitive raises the visibility / persistence of the
            // banner over a default-priority notification. macOS doesn't
            // expose a literal "duration" knob; the user's notification
            // style preference (Banners vs Alerts in System Settings)
            // also affects how long it stays on screen.
            content.interruptionLevel = .timeSensitive
            // Category lets the delegate identify our notifications when
            // routing the click action.
            content.categoryIdentifier = "photox.export.complete"

            let request = UNNotificationRequest(
                identifier: identifier, content: content, trigger: nil
            )
            do {
                try await UNUserNotificationCenter.current().add(request)
                log.info("posted export notification: \(content.categoryIdentifier, privacy: .public) id=\(identifier, privacy: .public)")
                // Darwin-notification side-channel so XCUITests can
                // observe the post without depending on the visual
                // banner (which doesn't render in the vm-e2e VM —
                // see scripts/vm-remote.sh::_dismiss_system_banners).
                // No-op in production (no observer).
                CFNotificationCenterPostNotification(
                    CFNotificationCenterGetDarwinNotifyCenter(),
                    CFNotificationName("dev.frostman.PhotoX.NotificationPosted.\(content.categoryIdentifier)" as CFString),
                    nil, nil, true)
            } catch {
                log.error("export notification add failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
