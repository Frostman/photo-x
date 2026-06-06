import AppKit
import CoreGraphics
import Foundation

/// A candidate display the user can present onto. Real entries wrap an
/// `NSScreen`; synthetic entries (used in DEBUG dev builds and E2E test
/// runs) carry the same metadata but no `NSScreen`, so the coordinator
/// can build an offscreen window for them.
struct DisplayTarget: Hashable, Identifiable, Sendable {
    enum Kind: Hashable, Sendable { case real, synthetic }

    let id: String
    let displayName: String
    let frame: CGRect
    let kind: Kind

    /// The underlying `NSScreen` for `.real` targets; nil for `.synthetic`.
    /// `NSScreen` is `@MainActor` and not `Sendable`; we treat the field
    /// as an opaque ref and only read it on the main actor (where the
    /// coordinator runs).
    @MainActor var screen: NSScreen? { _screenBox.value }
    private let _screenBox: ScreenBox

    init(id: String, displayName: String, frame: CGRect, kind: Kind, screen: NSScreen? = nil) {
        self.id = id
        self.displayName = displayName
        self.frame = frame
        self.kind = kind
        self._screenBox = ScreenBox(screen)
    }

    static func == (lhs: DisplayTarget, rhs: DisplayTarget) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Tiny ref box that lets `DisplayTarget` stay a value type even though
/// `NSScreen` is a reference. `nonisolated(unsafe)` is fine because we
/// only read `value` on the main actor (via the public `screen`
/// computed property, which is `@MainActor`).
final class ScreenBox: @unchecked Sendable {
    nonisolated(unsafe) let value: NSScreen?
    init(_ value: NSScreen?) { self.value = value }
}

/// Tracks the set of `DisplayTarget`s the user can present onto:
/// every non-built-in `NSScreen` plus a synthetic "Fake Display" entry
/// in DEBUG builds (or when `-photoxFakeExternalDisplay` is set).
///
/// Updates on `NSApplication.didChangeScreenParametersNotification`,
/// which fires whenever a display is attached, detached, resolution-
/// changed, or the AirPlay session toggles between mirror and extend.
@MainActor
@Observable
final class ExternalScreenWatcher {
    static let shared = ExternalScreenWatcher()

    /// Current display targets. Real targets first (in `NSScreen.screens`
    /// order), then the synthetic one if enabled.
    private(set) var targets: [DisplayTarget] = []

    /// Fired *after* `targets` is updated when one or more targets have
    /// gone away. Payload is the set of removed targets —
    /// `PresentationCoordinator` checks whether its `activeTarget` is in
    /// it and tears down if so.
    var onTargetsRemoved: (([DisplayTarget]) -> Void)?

    /// Predicate controlling synthetic-target injection. Default uses
    /// the DEBUG/-photoxFakeExternalDisplay heuristic; tests override to
    /// exercise the empty-state path.
    private let includesSynthetic: () -> Bool

    init(includesSynthetic: @escaping () -> Bool = ExternalScreenWatcher.defaultIncludesSynthetic) {
        self.includesSynthetic = includesSynthetic
        refresh()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleScreensChanged()
            }
        }
    }

    /// Dev builds always show the synthetic so the feature is
    /// manually exercisable via `just dev` without external hardware.
    /// Release builds opt in via the E2E launch flag.
    nonisolated static let defaultIncludesSynthetic: () -> Bool = {
        #if DEBUG
        return true
        #else
        return ProcessInfo.processInfo.arguments.contains("-photoxFakeExternalDisplay")
        #endif
    }

    private func handleScreensChanged() {
        let before = targets
        refresh()
        let afterIDs = Set(targets.map(\.id))
        let removed = before.filter { !afterIDs.contains($0.id) }
        if !removed.isEmpty {
            onTargetsRemoved?(removed)
        }
    }

    private func refresh() {
        var next: [DisplayTarget] = []
        for screen in NSScreen.screens where !Self.isBuiltIn(screen) {
            next.append(Self.realTarget(from: screen))
        }
        if includesSynthetic() {
            next.append(Self.syntheticTarget)
        }
        targets = next
    }

    static let syntheticTarget = DisplayTarget(
        id: "synthetic.fakeDisplay",
        displayName: "Fake Display 4K",
        frame: CGRect(x: -10_000, y: -10_000, width: 3840, height: 2160),
        kind: .synthetic,
        screen: nil
    )

    private static func realTarget(from screen: NSScreen) -> DisplayTarget {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        let screenID: String
        if let number = screen.deviceDescription[key] as? NSNumber {
            screenID = "real.\(number.uint32Value)"
        } else {
            screenID = "real.\(ObjectIdentifier(screen).hashValue)"
        }
        return DisplayTarget(
            id: screenID,
            displayName: screen.localizedName,
            frame: screen.frame,
            kind: .real,
            screen: screen
        )
    }

    /// True when `screen` is the laptop's internal panel. Uses
    /// `CGDisplayIsBuiltin` against the screen's CGDirectDisplayID
    /// (extracted from `deviceDescription[.screenNumber]`). Falls back
    /// to "matches NSScreen.main" only if the display ID can't be read,
    /// which means desk-clamshell setups still work but a misidentified
    /// screen would just appear in the menu as another external —
    /// harmless if surprising.
    private static func isBuiltIn(_ screen: NSScreen) -> Bool {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        if let number = screen.deviceDescription[key] as? NSNumber {
            return CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) != 0
        }
        return screen == NSScreen.main
    }
}
