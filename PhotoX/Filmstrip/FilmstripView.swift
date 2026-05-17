import SwiftUI

struct FilmstripView: View {
    @Bindable var state: ViewerState

    static let height: CGFloat = 108

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    if let shoot = state.shoot {
                        ForEach(Array(shoot.pairs.enumerated()), id: \.element.id) { idx, pair in
                            FilmstripThumbnailView(
                                pair: pair,
                                isSelected: idx == state.currentIndex,
                                thumbnail: state.thumbnails[pair.stem],
                                xmp: state.pairXMPs[pair.stem] ?? .empty,
                                onTap: { state.navigate(to: idx) },
                                onAppear: { state.requestThumbnail(for: pair) }
                            )
                            .id(idx)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .frame(height: Self.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(alignment: .top) {
                Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
            }
            .onAppear {
                proxy.scrollTo(state.currentIndex, anchor: .center)
            }
            .onChange(of: state.currentIndex) { _, newIdx in
                withAnimation(.easeInOut(duration: 0.18)) {
                    proxy.scrollTo(newIdx, anchor: .center)
                }
            }
        }
    }
}

struct FilmstripThumbnailView: View {
    let pair: PhotoPair
    let isSelected: Bool
    let thumbnail: CGImage?
    let xmp: XMPSidecar
    let onTap: () -> Void
    let onAppear: () -> Void

    private static let thumbHeight: CGFloat = 84
    private static let thumbAspectFallbackWidth: CGFloat = 126 // 3:2

    var body: some View {
        thumbnailImage
            .overlay(alignment: .topTrailing) { namePill.padding(3) }
            .overlay(alignment: .bottomTrailing) { scorePill.padding(3) }
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(isSelected ? Color.primary : Color.primary.opacity(0.12),
                            lineWidth: isSelected ? 2 : 1)
            )
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .onAppear(perform: onAppear)
            .help(pair.stem)
    }

    @ViewBuilder
    private var namePill: some View {
        Text(pair.stem)
            .font(.caption2.monospaced())
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(.black.opacity(0.7), in: Capsule())
    }

    @ViewBuilder
    private var thumbnailImage: some View {
        if let thumbnail {
            Image(decorative: thumbnail, scale: 1.0)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: Self.thumbHeight)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        } else {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.gray.opacity(0.18))
                .frame(width: Self.thumbAspectFallbackWidth, height: Self.thumbHeight)
                .overlay(
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white.opacity(0.4))
                )
        }
    }

    @ViewBuilder
    private var scorePill: some View {
        HStack(spacing: 3) {
            if let label = xmp.label, !label.isEmpty {
                Circle()
                    .fill(color(for: label))
                    .frame(width: 6, height: 6)
            }
            if xmp.isReject {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
            } else if let stars = xmp.starCount {
                Text("★\(stars)")
                    .font(.caption2.monospacedDigit().bold())
                    .foregroundStyle(.yellow)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(scorePillVisible ? AnyShapeStyle(Color.black.opacity(0.7)) : AnyShapeStyle(Color.clear),
                    in: Capsule())
    }

    private var scorePillVisible: Bool {
        xmp.isReject || xmp.starCount != nil || (xmp.label?.isEmpty == false)
    }

    private func color(for label: String) -> Color {
        switch label.lowercased() {
        case "red":    return .red
        case "yellow": return .yellow.opacity(0.85)
        case "green":  return .green
        case "blue":   return .blue
        case "purple": return .purple
        default:       return .gray
        }
    }
}
