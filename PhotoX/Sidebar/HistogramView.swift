import SwiftUI

struct HistogramView: View {
    let histogram: Histogram?

    var body: some View {
        Canvas { context, size in
            guard let h = histogram, h.totalPixels > 0 else { return }

            let allMax = max(h.red.max() ?? 0,
                             h.green.max() ?? 0,
                             h.blue.max() ?? 0)
            guard allMax > 0 else { return }

            // Clip the tallest 1% of the histogram so a single spike doesn't
            // squash everything else (common for skies/highlights).
            let cap = Int(Double(allMax) * 0.98)
            let scaleMax = max(cap, 1)

            drawChannel(in: context, size: size, bins: h.red,   color: .red,   scaleMax: scaleMax)
            drawChannel(in: context, size: size, bins: h.green, color: .green, scaleMax: scaleMax)
            drawChannel(in: context, size: size, bins: h.blue,  color: .blue,  scaleMax: scaleMax)
        }
        .background(.black.opacity(0.35))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(.white.opacity(0.1), lineWidth: 1)
        )
    }

    private func drawChannel(in context: GraphicsContext,
                             size: CGSize,
                             bins: [Int],
                             color: Color,
                             scaleMax: Int) {
        var path = Path()
        let stepX = size.width / 256.0
        path.move(to: CGPoint(x: 0, y: size.height))
        for (i, count) in bins.enumerated() {
            let x = CGFloat(i) * stepX
            let normalized = min(CGFloat(count) / CGFloat(scaleMax), 1.0)
            let y = size.height - normalized * size.height
            path.addLine(to: CGPoint(x: x, y: y))
        }
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.closeSubpath()
        context.fill(path, with: .color(color.opacity(0.55)))
    }
}
