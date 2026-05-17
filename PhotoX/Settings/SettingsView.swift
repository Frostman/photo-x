import AppKit
import SwiftUI

/// UserDefaults keys for persisted settings. Centralised so the @AppStorage
/// in SettingsView and the lookup-at-init in ViewerState / SamplePathProvider
/// agree on names.
enum SettingsKey {
    static let sidebarVisible    = "settings.sidebarVisibleByDefault"
    static let filmstripVisible  = "settings.filmstripVisibleByDefault"
    static let autoSwapToRAW     = "settings.autoSwapToRAW"
    static let sampleDirectory   = "settings.sampleDirectory"

    enum Defaults {
        static let sidebarVisible = true
        static let filmstripVisible = true
        static let autoSwapToRAW = false
        static let sampleDirectory = "/Users/frostman/workspace/personal/photo-x/sample"
    }
}

struct SettingsView: View {
    @AppStorage(SettingsKey.sidebarVisible)   private var sidebarVisible   = SettingsKey.Defaults.sidebarVisible
    @AppStorage(SettingsKey.filmstripVisible) private var filmstripVisible = SettingsKey.Defaults.filmstripVisible
    @AppStorage(SettingsKey.autoSwapToRAW)    private var autoSwapToRAW    = SettingsKey.Defaults.autoSwapToRAW
    @AppStorage(SettingsKey.sampleDirectory)  private var sampleDirectory  = SettingsKey.Defaults.sampleDirectory

    var body: some View {
        Form {
            Section("Layout") {
                Toggle("Show sidebar by default", isOn: $sidebarVisible)
                Toggle("Show filmstrip by default", isOn: $filmstripVisible)
            }

            Section("Image variant") {
                Toggle("Auto-swap HEIF → RAW when zoomed past 100 %", isOn: $autoSwapToRAW)
                    .help("One-way swap on the upward crossing only. Manual Z still toggles either direction.")
            }

            Section("Sample folder") {
                HStack {
                    TextField("Path", text: $sampleDirectory)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…") { pickSampleDirectory() }
                }
                Text("Loaded automatically on launch. Changes apply at next launch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 360)
        .navigationTitle("PhotoX Settings")
    }

    private func pickSampleDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            sampleDirectory = url.path
        }
    }
}

#Preview {
    SettingsView()
}
