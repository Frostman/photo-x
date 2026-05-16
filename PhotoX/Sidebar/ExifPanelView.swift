import SwiftUI

struct ExifPanelView: View {
    let summary: ExifSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            row("Camera", summary.camera)
            row("Lens", summary.lens)
            row("Shutter", summary.shutterSpeed)
            row("Aperture", summary.aperture)
            row("ISO", summary.iso)
            row("Focal", summary.focalLength)
            row("Exp Bias", summary.exposureCompensation)
            row("Dimensions", dimensionsString)
            row("Captured", capturedString)
        }
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
                    .lineLimit(2)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
        }
    }

    private var dimensionsString: String? {
        guard let w = summary.pixelWidth, let h = summary.pixelHeight else { return nil }
        return "\(w) × \(h)"
    }

    private var capturedString: String? {
        guard let date = summary.dateTime else { return nil }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
}
