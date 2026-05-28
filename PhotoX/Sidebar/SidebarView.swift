import SwiftUI

struct SidebarView: View {
    @Bindable var state: ViewerState
    /// Toggled by the small ladybug button in the Autofocus
    /// section header. When on, AFSettingsPanelView surfaces
    /// every parsed field including raw region coordinates —
    /// mainly for debugging Sony AF metadata parsing.
    /// Persisted across launches so a debugging session
    /// doesn't have to re-enable it after every restart.
    @AppStorage("ui.sidebar.afDebugDetails", store: AppDefaults.shared)
    private var afDebugDetails: Bool = false

    static let width: CGFloat = 280

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section(title: "Decisions") {
                        DecisionsPanelView(state: state)
                    }

                    section(title: "Histogram") {
                        HistogramView(histogram: state.currentHistogram)
                            .frame(height: 140)
                    }

                    if let exif = state.displayedExif {
                        section(title: "EXIF") {
                            ExifPanelView(summary: exif)
                        }
                    }

                    if !state.displayedAFSettings.isEmpty {
                        autofocusSection
                    }
                }
                .padding(12)
            }
        }
        .frame(width: Self.width)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .leading) {
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1)
        }
        .accessibilityIdentifier("sidebar.container")
    }

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.smallCaps())
                .foregroundStyle(.secondary)
            content()
        }
    }

    /// Custom section for Autofocus — uses the same header
    /// style as `section(...)` but adds a small ladybug toggle
    /// to the right of the title that flips between the terse
    /// summary and the full debug dump (region coordinates,
    /// focus-frame size, etc.).
    private var autofocusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Autofocus")
                    .font(.caption.smallCaps())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button {
                    afDebugDetails.toggle()
                } label: {
                    Image(systemName: "ladybug")
                        .font(.caption2)
                        .foregroundStyle(afDebugDetails
                                          ? Color.accentColor
                                          : .secondary)
                }
                .buttonStyle(.plain)
                .help(afDebugDetails
                      ? "Hide AF debug details"
                      : "Show AF debug details (region coordinates, frame size)")
                .accessibilityIdentifier("sidebar.af.debugToggle")
            }
            AFSettingsPanelView(
                settings: state.displayedAFSettings,
                regions: state.displayedAFRegions,
                showDebug: afDebugDetails
            )
        }
    }
}
