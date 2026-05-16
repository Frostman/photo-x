import SwiftUI

struct SidebarView: View {
    @Bindable var state: ViewerState

    static let width: CGFloat = 280

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Histogram")
                .font(.caption.smallCaps())
                .foregroundStyle(.secondary)
            HistogramView(histogram: state.currentHistogram)
                .frame(height: 140)
            Spacer()
        }
        .padding(12)
        .frame(width: Self.width)
        .background(Color(white: 0.10))
        .overlay(alignment: .leading) {
            Rectangle().fill(.black.opacity(0.6)).frame(width: 1)
        }
    }
}
