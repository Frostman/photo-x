import SwiftUI

/// SwiftUI focus-chain key carrying the focused window's
/// `ViewerState`. Each `WindowRoot` publishes its state via
/// `.focusedValue(\.viewerState, viewerState)`; menu commands at
/// the App scope read it back with `@FocusedValue(\.viewerState)`
/// so actions (Undo / Redo, View → Fit, Usage Stats…) target the
/// frontmost window's data instead of a stale single instance.
private struct ViewerStateFocusedKey: FocusedValueKey {
    typealias Value = ViewerState
}

extension FocusedValues {
    var viewerState: ViewerState? {
        get { self[ViewerStateFocusedKey.self] }
        set { self[ViewerStateFocusedKey.self] = newValue }
    }
}
