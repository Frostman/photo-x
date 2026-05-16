import SwiftUI

struct ContentView: View {
    @Bindable var state: ViewerState

    var body: some View {
        VStack(spacing: 12) {
            Text("PhotoX")
                .font(.title)
            Text(state.pair?.stem ?? "No pair loaded")
                .foregroundStyle(.secondary)
                .font(.callout)
        }
        .frame(minWidth: 800, minHeight: 600)
    }
}

#Preview {
    ContentView(state: ViewerState())
}
