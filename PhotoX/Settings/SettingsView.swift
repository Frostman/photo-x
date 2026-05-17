import AppKit
import SwiftUI

/// UserDefaults keys for persisted settings. Centralised so the @AppStorage
/// in SettingsView and the lookup-at-init in ViewerState / SamplePathProvider
/// agree on names.
enum SettingsKey {
    static let appearance        = "settings.appearance"
    static let sidebarVisible    = "settings.sidebarVisibleByDefault"
    static let filmstripVisible  = "settings.filmstripVisibleByDefault"
    static let autoSwapToRAW     = "settings.autoSwapToRAW"
    static let afOverlayVisible  = "settings.afOverlayVisibleByDefault"
    static let autoAdvance        = "settings.autoAdvanceAfterRating"
    static let autoAdvanceSidebar = "settings.autoAdvanceAfterSidebarRating"
    static let defaultFolderPath  = "settings.defaultFolderPath"

    enum Defaults {
        static let appearance = AppearanceMode.system.rawValue
        static let sidebarVisible = true
        static let filmstripVisible = true
        static let autoSwapToRAW = false
        static let afOverlayVisible = false
        static let autoAdvance = false
        static let autoAdvanceSidebar = false
        static let defaultFolderPath = ""  // empty = no auto-load on launch
    }
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    /// nil means "follow the system" — SwiftUI inherits the OS appearance.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

struct SettingsView: View {
    @AppStorage(SettingsKey.appearance)        private var appearanceRaw     = SettingsKey.Defaults.appearance
    @AppStorage(SettingsKey.sidebarVisible)    private var sidebarVisible    = SettingsKey.Defaults.sidebarVisible
    @AppStorage(SettingsKey.filmstripVisible)  private var filmstripVisible  = SettingsKey.Defaults.filmstripVisible
    @AppStorage(SettingsKey.autoSwapToRAW)     private var autoSwapToRAW     = SettingsKey.Defaults.autoSwapToRAW
    @AppStorage(SettingsKey.afOverlayVisible)  private var afOverlayVisible  = SettingsKey.Defaults.afOverlayVisible
    @AppStorage(SettingsKey.autoAdvance)        private var autoAdvance        = SettingsKey.Defaults.autoAdvance
    @AppStorage(SettingsKey.autoAdvanceSidebar) private var autoAdvanceSidebar = SettingsKey.Defaults.autoAdvanceSidebar
    @AppStorage(SettingsKey.defaultFolderPath) private var defaultFolderPath = SettingsKey.Defaults.defaultFolderPath

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $appearanceRaw) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .help("System follows the macOS appearance. Light / Dark force one.")
            }

            Section("Layout") {
                Toggle("Show sidebar by default", isOn: $sidebarVisible)
                Toggle("Show filmstrip by default", isOn: $filmstripVisible)
            }

            Section("Overlays") {
                Toggle("Show AF data by default", isOn: $afOverlayVisible)
                    .help("Draws focus boxes on the image. Toggle with A at any time.")
            }

            Section("Image variant") {
                Toggle("Auto-swap HEIF → RAW when zoomed past 100 %", isOn: $autoSwapToRAW)
                    .help("One-way swap on the upward crossing only. Manual Z still toggles either direction.")
            }

            Section("Workflow") {
                Toggle("Auto-advance after keyboard rating", isOn: $autoAdvance)
                    .help("When you use a keyboard shortcut (1–5, Shift+1–5, R) to set a star, label, or reject, jump to the next pair. Clearing a rating does not advance.")
                Toggle("Auto-advance after sidebar rating", isOn: $autoAdvanceSidebar)
                    .help("When you click a star, label dot, or the Reject button in the sidebar Decisions panel, jump to the next pair.")
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
        .frame(width: 620, height: 660)
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
