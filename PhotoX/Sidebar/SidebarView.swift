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

                    if let exif = state.displayedExif {
                        section(title: "EXIF") {
                            ExifPanelView(summary: exif)
                        }
                    }

                    if !state.displayedAFSettings.isEmpty {
                        section(title: "Autofocus") {
                            AFSettingsPanelView(settings: state.displayedAFSettings)
                        }
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
