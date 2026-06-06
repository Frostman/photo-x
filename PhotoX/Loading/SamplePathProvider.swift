import Foundation
import IndexingCore

enum SamplePathProvider {
    /// The user's configured default folder, or nil if not set / not present.
    /// Env var PHOTOX_SAMPLE_DIR wins (for Xcode-scheme overrides), then the
    /// UserDefaults setting from the Settings window.
    static func defaultDirectory() -> URL? {
        if let env = ProcessInfo.processInfo.environment["PHOTOX_SAMPLE_DIR"], !env.isEmpty {
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath)
        }
        if let custom = AppDefaults.shared.string(forKey: SettingsKey.defaultFolderPath),
           !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        return nil
    }

    /// Resolves the configured default into a (shoot, focus) tuple if the
    /// folder exists AND has at least one entry. Returns nil otherwise so the
    /// app can open with an empty state instead of an error.
    static func resolveShoot() -> (shoot: Shoot, focus: PhotoEntry)? {
        guard let dir = defaultDirectory() else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir),
              isDir.boolValue else { return nil }
        let shoot = ShootScanner.scan(folder: dir)
        guard let first = shoot.entries.first else { return nil }
        return (shoot, first)
    }
}
