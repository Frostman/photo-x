import SwiftUI
import IndexingCore

struct ExifPanelView: View {
    let summary: ExifSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            row("Camera",     "camera",     summary.camera)
            row("Lens",       "lens",       summary.lens)
            row("Shutter",    "shutter",    summary.shutterSpeed)
            row("Aperture",   "aperture",   summary.aperture)
            row("ISO",        "iso",        summary.iso)
            row("Focal",      "focal",      summary.focalLength)
            row("Exp Bias",   "expBias",    summary.exposureCompensation)
            row("Dimensions", "dimensions", dimensionsString)
            row("Captured",   "captured",   capturedString)
        }
        // No container-level identifier — SwiftUI would propagate it
        // to every descendant a11y node and clobber the per-row keys.
    }

    /// `key` is the stable XCUITest identifier suffix — independent of the
    /// localised label string so renaming the user-facing text doesn't break
    /// E2E assertions.
    @ViewBuilder
    private func row(_ label: String, _ key: String, _ value: String?) -> some View {
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
                    .accessibilityIdentifier("exif.row.\(key).value")
                Spacer(minLength: 0)
            }
            .accessibilityIdentifier("exif.row.\(key)")
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
