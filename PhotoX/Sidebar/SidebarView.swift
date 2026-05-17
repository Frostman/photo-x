import SwiftUI

struct SidebarView: View {
    @Bindable var state: ViewerState

    static let width: CGFloat = 280

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Always render the Decisions section so its space is reserved
                // and the rest of the sidebar doesn't reflow as you navigate
                // through rated / unrated photos.
                section(title: "Decisions") {
                    DecisionsPanelView(xmp: state.currentXMP)
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

                section(title: "Perf") {
                    PerfPanelView(stats: state.perfStats)
                }
            }
            .padding(12)
        }
        .frame(width: Self.width)
        .background(Color(white: 0.10))
        .overlay(alignment: .leading) {
            Rectangle().fill(.black.opacity(0.6)).frame(width: 1)
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
