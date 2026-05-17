import SwiftUI

struct PerfPanelView: View {
    let stats: ViewerState.PerfStats

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            row("Image", imageDescription)
            row("AF", afDescription)
            row("XMP", stats.xmpMS.map { format($0) })
        }
    }

    private var imageDescription: String? {
        guard let ms = stats.imageMS else { return nil }
        return "\(format(ms)) \(stats.imageCached ? "(cache)" : "(fresh)")"
    }

    private var afDescription: String? {
        guard let ms = stats.afMS else { return nil }
        return "\(format(ms)) \(stats.afCached ? "(cache)" : "(exiftool)")"
    }

    private func format(_ ms: Double) -> String {
        if ms < 10 {
            return String(format: "%.1f ms", ms)
        }
        return "\(Int(ms.rounded())) ms"
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label)
                    .font(.caption.smallCaps())
                    .foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .leading)
                Text(value)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
        }
    }
}
