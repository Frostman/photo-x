import SwiftUI

struct AFSettingsPanelView: View {
    let settings: AFSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            row("Focus Mode", settings.focusMode)
            row("AF Area", settings.afAreaMode)
            row("Tracking", settings.afTracking)
            row("Distance", settings.focusDistance)
            row("Points Used", settings.pointsUsed.map { "\($0)" })
            row("Frame Size", settings.focusFrameSize)
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
                Spacer(minLength: 0)
            }
        }
    }
}
