import AppKit
import SwiftUI

/// UserDefaults keys for persisted settings. Centralised so the @AppStorage
/// in SettingsView and the lookup-at-init in ViewerState / SamplePathProvider
/// agree on names.
enum SettingsKey {
    static let sidebarVisible    = "settings.sidebarVisibleByDefault"
    static let filmstripVisible  = "settings.filmstripVisibleByDefault"
    static let autoSwapToRAW     = "settings.autoSwapToRAW"
    static let defaultFolderPath = "settings.defaultFolderPath"

    enum Defaults {
        static let sidebarVisible = true
        static let filmstripVisible = true
        static let autoSwapToRAW = false
        static let defaultFolderPath = ""  // empty = no auto-load on launch
    }
}

struct SettingsView: View {
    @AppStorage(SettingsKey.sidebarVisible)    private var sidebarVisible    = SettingsKey.Defaults.sidebarVisible
    @AppStorage(SettingsKey.filmstripVisible)  private var filmstripVisible  = SettingsKey.Defaults.filmstripVisible
    @AppStorage(SettingsKey.autoSwapToRAW)     private var autoSwapToRAW     = SettingsKey.Defaults.autoSwapToRAW
    @AppStorage(SettingsKey.defaultFolderPath) private var defaultFolderPath = SettingsKey.Defaults.defaultFolderPath

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

            Section("Default folder") {
                HStack {
                    TextField("Path (empty = none)", text: $defaultFolderPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…") { pickFolder() }
                    Button("Reset") { defaultFolderPath = "" }
                        .disabled(defaultFolderPath.isEmpty)
                }
                Text("Loaded automatically on launch. If empty or missing, the window opens blank and you can pick a folder with ⌘O.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 360)
        .navigationTitle("PhotoX Settings")
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            defaultFolderPath = url.path
        }
    }
}

#Preview {
    SettingsView()
}
