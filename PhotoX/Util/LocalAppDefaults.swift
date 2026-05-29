import Foundation

/// `UserDefaults` scoped to the **running build's bundle ID** — prod
/// and dev keep separate copies. Sibling to `AppDefaults` (whose
/// shared store is wired to always read the production bundle so
/// dev inherits the user's real prefs).
///
/// 99% of PhotoX settings should live in `AppDefaults.shared`. Use
/// this *only* for state tied to the specific installation:
///
/// - Helpers registered via `SMAppService` (Login Items are
///   per-bundle: prod and dev each have their own registered job,
///   so the toggle that drives register/unregister must also be
///   per-bundle, or toggling in dev would flip prod's helper too).
/// - Anything else where mirroring across builds would cause
///   double-registration / conflicting ownership.
///
/// Implementation is `UserDefaults.standard`, which AppKit
/// already domain-scopes to the running app's bundle ID
/// (`dev.frostman.PhotoX` for Release, `…PhotoX.debug` for Debug,
/// and the UI-test scratch suite under `-photoxUITestMode`).
///
/// E2E test isolation mirrors `AppDefaults`: under
/// `-photoxUITestMode YES` we route through an isolated scratch
/// suite so test runs can never flip the user's real
/// per-installation state. The scratch is wiped on launch unless
/// `-photoxUITestPreserveDefaults YES` is also set.
enum LocalAppDefaults {
    static let shared: UserDefaults = {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-photoxUITestMode"),
           let scratch = UserDefaults(suiteName: testScratchSuite) {
            if !args.contains("-photoxUITestPreserveDefaults") {
                scratch.removePersistentDomain(forName: testScratchSuite)
            }
            return scratch
        }
        return .standard
    }()

    /// Distinct suite name for E2E test runs — kept separate from
    /// `AppDefaults`'s test scratch so a single test process can
    /// flip shared and local settings independently without
    /// cross-contamination.
    private static let testScratchSuite = "dev.frostman.PhotoX.local.uitest"
}
