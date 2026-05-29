import SwiftUI

/// Top-level mode of the main window. Drives which content the
/// shoot-loaded ContentView shows: the viewer (canvas + sidebar +
/// filmstrip + status bar) or the inline export pane. Owned as
/// `@State` on `ContentView`; switched by the segmented toolbar
/// picker and the ⌘1 / ⌘2 keyboard shortcuts.
///
/// Plain enum on purpose — not `@AppStorage`. Mode should reset
/// to `.view` on every launch; landing in `.export` with no
/// loaded shoot would be a dead end.
enum WorkspaceMode: String, CaseIterable, Hashable, Sendable {
    case view
    case export
}

/// All focus targets that exist across the whole workspace.
/// A single shared `@FocusState<WorkspaceFocus?>` in
/// `ContentView` lets SwiftUI transition focus atomically
/// between tabs — without this, the previous tab's FocusState
/// going false doesn't reliably re-engage the new tab's
/// target via AppKit's responder chain, leaving keybindings
/// dead until the user clicks.
///
/// When adding a new tab that owns a focusable element (text
/// field, etc.), add its case here and bind via
/// `.focused(focus, equals: .myTarget)`.
enum WorkspaceFocus: Hashable, Sendable {
    /// ContentView's focusable container — the View tab's
    /// catch-all for canvas keybindings (`.onKeyPress`).
    case canvas
    /// Export pane's project-name `TextField`.
    case exportProjectName
}

/// Declarative per-tab metadata. The toolbar tab picker, the
/// View menu shortcuts, and the focus transition all read
/// from `workspaceTabs` below — no hard-coding per tab.
///
/// Adding a new workspace tab is `WorkspaceMode.<new>` +
/// `WorkspaceFocus.<targetIfAny>` + appending a
/// `WorkspaceTabConfig` here + writing the tab's View struct
/// + adding the case branch in `ContentView`'s body switch.
struct WorkspaceTabConfig: Identifiable {
    let mode: WorkspaceMode
    let title: String
    /// SF Symbol shown on the tab segment.
    let icon: String
    /// Where to send keyboard focus when this tab becomes
    /// active. `nil` means "no focus on entry" — user input
    /// fields stay un-focused until the user explicitly
    /// engages them (e.g., presses Tab on the Export tab).
    let defaultFocus: WorkspaceFocus?
    /// `⌘<key>` menu shortcut.
    let shortcut: KeyEquivalent
    /// `true` when the tab needs a loaded shoot to be
    /// meaningful. On `state.shoot == nil`, ContentView
    /// auto-reverts away from any `requiresShoot` tab back to
    /// the first non-requiring tab (today: `.view`). Drives
    /// the close-shoot fallback from a single place instead
    /// of bespoke per-tab checks in `ModeWiring`.
    let requiresShoot: Bool

    var id: WorkspaceMode { mode }
}

let workspaceTabs: [WorkspaceTabConfig] = [
    .init(mode: .view,
          title: "View",
          icon: "photo.stack",
          defaultFocus: .canvas,
          shortcut: "1",
          // View works on the empty starter screen too.
          requiresShoot: false),
    .init(mode: .export,
          title: "Export",
          icon: "arrow.up.doc.fill",
          // Export pane opens with no field focused — pressing
          // Tab focuses the project-name TextField. Avoids the
          // accidental capture of typed shortcuts (digits,
          // letters) the moment a user lands on the Export tab.
          defaultFocus: nil,
          shortcut: "2",
          // Nothing to export without a loaded shoot.
          requiresShoot: true),
]

/// Lookup helper — kept tight so call sites don't open-code
/// `first(where:)` themselves.
func workspaceTab(for mode: WorkspaceMode) -> WorkspaceTabConfig {
    // Force-unwrap is fine: `workspaceTabs` is an internal
    // static list and must cover every `WorkspaceMode` case
    // (a missing entry is a programmer error caught at first
    // launch).
    workspaceTabs.first(where: { $0.mode == mode })!
}
