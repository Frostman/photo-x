import SwiftUI

struct SidebarView: View {
    @Bindable var state: ViewerState

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

                    if let exif = state.currentExif {
                        section(title: "EXIF") {
                            ExifPanelView(summary: exif)
                        }
                    }

                    if !state.currentAFSettings.isEmpty {
                        section(title: "Autofocus") {
                            AFSettingsPanelView(settings: state.currentAFSettings)
                        }
                    }
                }
                .padding(12)
            }

            // Pinned footer: always visible regardless of scroll position.
            VStack(alignment: .leading, spacing: 8) {
                Divider()
                Text("Perf")
                    .font(.caption.smallCaps())
                    .foregroundStyle(.secondary)
                PerfPanelView(stats: state.perfStats)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: Self.width)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .leading) {
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1)
        }
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
}
