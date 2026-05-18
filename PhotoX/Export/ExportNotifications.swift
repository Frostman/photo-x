import Foundation
import UserNotifications

/// Thin wrapper around `UNUserNotificationCenter` for the Export feature.
/// Authorization is requested lazily on the first attempt to post.
@MainActor
enum ExportNotifications {

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

    static func postDestinationComplete(
        dest: ExportSettings.Destination,
        summary: ExportRunner.Summary
    ) {
        let basename = (dest.path as NSString).lastPathComponent
        let title = "Export to \(basename) complete"
        let body = summaryLine(summary)
        post(title: title, body: body, identifier: "photox.export.dest.\(dest.id.uuidString)")
    }

    static func postAllComplete(
        summaries: [(ExportSettings.Destination, ExportRunner.Summary)]
    ) {
        let totalCopied = summaries.reduce(0) { $0 + $1.1.copied }
        let totalSkipped = summaries.reduce(0) { $0 + $1.1.skipped }
        let totalDeleted = summaries.reduce(0) { $0 + $1.1.deleted }
        let errors = summaries.reduce(0) { $0 + $1.1.errors.count }
        let body = "\(summaries.count) destinations · "
            + "\(totalCopied) copied · "
            + "\(totalSkipped) skipped"
            + (totalDeleted > 0 ? " · \(totalDeleted) deleted" : "")
            + (errors > 0     ? " · \(errors) errors"        : "")
        post(title: "All exports finished", body: body,
             identifier: "photox.export.allcomplete.\(UUID().uuidString)")
    }

    private static func summaryLine(_ summary: ExportRunner.Summary) -> String {
        var parts = ["\(summary.copied) copied", "\(summary.skipped) skipped"]
        if summary.deleted > 0  { parts.append("\(summary.deleted) deleted") }
        if !summary.errors.isEmpty { parts.append("\(summary.errors.count) errors") }
        return parts.joined(separator: " · ")
    }

    private static func post(title: String, body: String, identifier: String) {
        Task {
            guard await requestAuthorizationIfNeeded() else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: identifier, content: content, trigger: nil
            )
            try? await UNUserNotificationCenter.current().add(request)
        }
    }
}
