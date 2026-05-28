import SwiftUI

struct AFSettingsPanelView: View {
    let settings: AFSettings
    /// AF regions read from the image's metadata (primary focus
    /// box, focal-plane points, faces, subjects). Only rendered
    /// when `showDebug` is on — the regular sidebar stays terse.
    let regions: [AFRegion]
    /// When on, the panel surfaces every parsed field including
    /// raw region coordinates. Toggled from the sidebar header
    /// via the small ladybug button; mainly for debugging
    /// Sony AF metadata parsing.
    let showDebug: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            row("Focus Mode", settings.focusMode)
            row("AF Area", settings.afAreaMode)
            row("Tracking", settings.afTracking)
            row("Distance", settings.focusDistance)
            row("Points Used", settings.pointsUsed.map { "\($0)" })
            // Was the focus position actually written to the file?
            // True when the Sony:FocusLocation tag yielded a usable
            // primary-focus region (non-missing, non-all-zero — see
            // ExifToolRunner.isFocusLocationAllZero). Surfaced so it's
            // obvious which shots have AF metadata vs which were taken
            // in MF / had it stripped.
            row("Location", hasPrimaryFocus ? "Available" : "Missing")
            if showDebug {
                row("Frame Size", settings.focusFrameSize)
                if !regions.isEmpty {
                    Divider().padding(.vertical, 4)
                    Text("Regions (\(regions.count))")
                        .font(.caption.smallCaps())
                        .foregroundStyle(.secondary)
                    ForEach(regions) { region in
                        regionRow(region)
                    }
                }
            }
        }
    }

    private var hasPrimaryFocus: Bool {
        regions.contains(where: { $0.kind == .primaryFocus })
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
                Spacer(minLength: 0)
            }
        }
    }

    private func regionRow(_ r: AFRegion) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(r.kind.rawValue)
                    .font(.caption2.smallCaps())
                    .foregroundStyle(.secondary)
                if let label = r.label, !label.isEmpty {
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            // Rect in image-pixel coords (origin top-left, y-down).
            Text("(\(Int(r.rect.minX)), \(Int(r.rect.minY))) \(Int(r.rect.width))×\(Int(r.rect.height))")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.primary)
        }
    }
}
