import Foundation

/// UserDefaults to use throughout PhotoX. Release builds use the standard
/// domain (their own bundle ID, `dev.frostman.PhotoX`). DEBUG builds —
/// which have a distinct bundle ID, `dev.frostman.PhotoX.debug`, so that
/// notifications route back to the dev binary instead of the installed
/// release — explicitly target the production domain so the dev build
/// sees real recents / favorites / export settings / theme choices /
/// etc. Lets us iterate UI against actual data without recreating it.
///
/// E2E test runs (launched with `-photoxUITestMode YES`) get a third,
/// completely isolated domain that's wiped at the start of every test
/// process. The released app and `just dev` share production prefs;
/// the test runner can never modify them, append recent folders, or
/// flip any settings the user has tuned. Tests "just load defaults"
/// — they start from the SettingsKey.Defaults values every time.
///
/// Trade-off (non-test): mutations from the dev build DO affect the
/// release app's settings (single shared prefs file). Usually what
/// you want when debugging real workflows.
///
/// All `@AppStorage(_, store:)` call sites and the persistence singletons
/// (RecentShoots / FavoriteShoots / ExportSettings) read from this.
/// Anything that calls `UserDefaults.standard` directly will use the
/// Debug build's own (separate) domain — that's a bug if it's about
/// our settings, fine if it's about AppKit machinery (e.g. the
/// `AppleActionOnDoubleClick` window behaviour override).
enum AppDefaults {
    static let shared: UserDefaults = {
        // E2E test mode: a per-process scratch suite. Cleared on each
        // launch so every test starts from defaults; isolated from
        // production so recent-folder appends, settings toggles, etc.
        // can't leak into the user's real PhotoX install.
        if ProcessInfo.processInfo.arguments.contains("-photoxUITestMode"),
           let scratch = UserDefaults(suiteName: testScratchSuite) {
            scratch.removePersistentDomain(forName: testScratchSuite)
            return scratch
        }
        #if DEBUG
        if let prod = UserDefaults(suiteName: productionBundleID) {
            return prod
        }
        #endif
        return .standard
    }()

    /// Bundle ID of the Release build. Hardcoded because the Debug build
    /// can't read its own bundle id and discover "the other one".
    private static let productionBundleID = "dev.frostman.PhotoX"

    /// Distinct suite name for E2E test runs — lives in the PhotoX
    /// sandbox's Preferences folder as a separate plist, so production
    /// (`dev.frostman.PhotoX.plist`) never sees writes from tests.
    private static let testScratchSuite = "dev.frostman.PhotoX.uitest"
}
