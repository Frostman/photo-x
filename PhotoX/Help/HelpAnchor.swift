import SwiftUI

/// Logical ID for each UI region the annotated help overlay
/// can point at. Annotations are authored in
/// `HelpAnnotationOverlay`; each entry's `id` here pairs with
/// a `.helpAnchor(_:)` modifier at the corresponding call
/// site so the overlay knows where to draw its bracket +
/// callout.
enum HelpAnchorID: String, CaseIterable, Hashable, Sendable {
    case canvas
    case filmstrip
    case decisions
    case histogram
    case exif
    case autofocus
    case indexerChip
    /// Cluster of the three view-control widgets in the
    /// status bar — sort menu, collapse-bursts toggle, and
    /// the star/reject/unrated filter toggles. Annotated as
    /// one block instead of three so the callouts don't
    /// stack on top of each other in a narrow vertical
    /// gutter above the status bar.
    case viewControls
    /// Segmented View | Export picker in the toolbar.
    /// Only present once a shoot is loaded.
    case workspaceMode
}

/// Shared store the annotated help overlay reads from. Frames
/// are reported in the `"help"` named coordinate space pinned
/// at the root `ContentView` ZStack, so callouts can be
/// positioned in absolute window coordinates without per-view
/// math.
///
/// One instance lives in `ContentView` as `@State`. The
/// `.onPreferenceChange(HelpAnchorPreferenceKey.self)`
/// observer on the root ZStack writes rects in; views that
/// disappear stop publishing and their entries are pruned to
/// `nil` on the next reduce, so the overlay naturally hides
/// callouts for hidden panels (sidebar off, etc.).
@Observable
final class HelpAnchorStore {
    var rects: [HelpAnchorID: CGRect] = [:]
}

/// PreferenceKey that bubbles `(id, frame)` pairs from every
/// `.helpAnchor(_:)` modifier up to the root coordinator. We
/// merge by taking the most-recent value per key so two
/// publishes for the same id in one pass don't fight; in
/// practice each anchor appears on exactly one view.
struct HelpAnchorPreferenceKey: PreferenceKey {
    static var defaultValue: [HelpAnchorID: CGRect] { [:] }
    static func reduce(value: inout [HelpAnchorID: CGRect],
                       nextValue: () -> [HelpAnchorID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// Publish this view's frame to the help-overlay store
    /// under `id`. The frame is reported in the `"help"`
    /// named coordinate space, which the root ContentView
    /// ZStack installs via `.coordinateSpace(name: "help")`.
    /// Zero behavioural cost when the overlay isn't open —
    /// the publication is just an inert preference write.
    func helpAnchor(_ id: HelpAnchorID) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: HelpAnchorPreferenceKey.self,
                    value: [id: proxy.frame(in: .named("help"))]
                )
            }
        )
    }
}
