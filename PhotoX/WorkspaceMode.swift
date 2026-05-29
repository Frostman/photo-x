import Foundation

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
