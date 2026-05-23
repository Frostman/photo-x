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
    /// Centred circular ProgressView shown on the canvas while a new
    /// image is loading (texture hasn't bound yet). Toggleable so
    /// users who find it distracting can disable it via
    /// `defaults write … settings.showCanvasLoadingIndicator -bool NO`.
    static let showCanvasLoadingIndicator = "settings.showCanvasLoadingIndicator"
    /// When on, the filmstrip hides all-but-the-first frame of each
    /// burst; the burst the user is currently inside auto-expands.
    /// Toggled by the rectangle.stack button in the status bar.
    static let collapseBursts = "settings.collapseBursts"
    /// Which burst siblings the `g` shortcut rejects. Values are
    /// `GRejectScope.rawValue`: "unrated" (only siblings without a
    /// star rating — color label alone does NOT protect, since
    /// labels are organizational, not a culling decision) or
    /// "all" (every other member of the burst).
    static let gRejectScope = "settings.gRejectScope"

    // Advanced — caches & prefetch. All three are read at startup
    // by the cache singletons + the prefetch path, AND live-applied
    // from SettingsView via setCapacity / setByteCapacity.
    /// Max GPU textures held in `MTLTextureCache`. Larger = more
    /// hits when revisiting frames, more GPU memory.
    static let textureCacheCapacity = "settings.textureCacheCapacity"
    /// Max raw HEIF/HEIC/JPG bytes held in `PreviewBytesCache` (in
    /// MB). Larger = fewer re-reads from slow source media.
    static let previewBytesCacheMB  = "settings.previewBytesCacheMB"
    /// How many neighbour frames to pre-decode on each side of the
    /// focused frame. 0 = no prefetch. >1 may contend with the
    /// user's own nav uploads (observed +600 ms at ±2 in earlier
    /// testing).
    static let prefetchRadius       = "settings.prefetchRadius"

    enum Defaults {
        static let appearance = AppearanceMode.system.rawValue
        static let sidebarVisible = true
        static let filmstripVisible = true
        static let autoSwapToRAW = false
        static let afOverlayVisible = false
        static let autoAdvance = false
        static let autoAdvanceSidebar = false
        static let defaultFolderPath = ""  // empty = no auto-load on launch
        static let showCanvasLoadingIndicator = false
        static let collapseBursts = false
        static let gRejectScope = "unrated"
        static let textureCacheCapacity = 32
        static let previewBytesCacheMB  = 2048    // 2 GB
        static let prefetchRadius       = 1
    }
}

/// Behaviour of the `g` shortcut: which burst siblings get rejected.
enum GRejectScope: String, CaseIterable, Identifiable, Sendable {
    case unrated   // skip starred / labeled / already-rejected siblings
    case all       // reject every other member of the burst
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .unrated: return "Only unrated siblings"
        case .all:     return "All other siblings"
        }
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

    /// SF Symbol used in the toolbar cycle button. The half-filled circle is
    /// Apple's canonical "Auto / System" indicator (used in iOS Settings →
    /// Display & Brightness).
    var toolbarSymbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light:  return "sun.max"
        case .dark:   return "moon"
        }
    }

    /// Next mode in the System → Light → Dark → System cycle.
    var next: AppearanceMode {
        switch self {
        case .system: return .light
        case .light:  return .dark
        case .dark:   return .system
        }
    }
}

struct SettingsView: View {
    @AppStorage(SettingsKey.appearance,         store: AppDefaults.shared) private var appearanceRaw       = SettingsKey.Defaults.appearance
    @AppStorage(SettingsKey.sidebarVisible,     store: AppDefaults.shared) private var sidebarVisible      = SettingsKey.Defaults.sidebarVisible
    @AppStorage(SettingsKey.filmstripVisible,   store: AppDefaults.shared) private var filmstripVisible    = SettingsKey.Defaults.filmstripVisible
    @AppStorage(SettingsKey.autoSwapToRAW,      store: AppDefaults.shared) private var autoSwapToRAW       = SettingsKey.Defaults.autoSwapToRAW
    @AppStorage(SettingsKey.afOverlayVisible,   store: AppDefaults.shared) private var afOverlayVisible    = SettingsKey.Defaults.afOverlayVisible
    @AppStorage(SettingsKey.autoAdvance,        store: AppDefaults.shared) private var autoAdvance         = SettingsKey.Defaults.autoAdvance
    @AppStorage(SettingsKey.autoAdvanceSidebar, store: AppDefaults.shared) private var autoAdvanceSidebar  = SettingsKey.Defaults.autoAdvanceSidebar
    @AppStorage(SettingsKey.defaultFolderPath,  store: AppDefaults.shared) private var defaultFolderPath   = SettingsKey.Defaults.defaultFolderPath
    @AppStorage(SettingsKey.showCanvasLoadingIndicator, store: AppDefaults.shared) private var showCanvasLoadingIndicator = SettingsKey.Defaults.showCanvasLoadingIndicator
    @AppStorage(SettingsKey.gRejectScope,       store: AppDefaults.shared) private var gRejectScopeRaw     = SettingsKey.Defaults.gRejectScope
    @AppStorage(SettingsKey.textureCacheCapacity, store: AppDefaults.shared) private var textureCacheCapacity = SettingsKey.Defaults.textureCacheCapacity
    @AppStorage(SettingsKey.previewBytesCacheMB,  store: AppDefaults.shared) private var previewBytesCacheMB  = SettingsKey.Defaults.previewBytesCacheMB
    @AppStorage(SettingsKey.prefetchRadius,       store: AppDefaults.shared) private var prefetchRadius       = SettingsKey.Defaults.prefetchRadius

    /// Injected by `PhotoXApp` so Settings → Advanced can read live
    /// cache stats from the currently-loaded shoot. nil means no
    /// shoot is open (per-item rows show empty state).
    @Environment(ViewerState.self) private var state

    /// Polled snapshot of the four caches' live counts/bytes.
    /// Refreshed by the `.task` below every 1 s while Settings is
    /// open. We snapshot rather than reading per-render because the
    /// Metal + actor caches don't conform to @Observable.
    @State private var advancedStats = AdvancedCacheStats()

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
                Toggle("Auto-swap HIF/JPG → RAW when zoomed past 100 %", isOn: $autoSwapToRAW)
                    .help("One-way swap on the upward crossing only. Manual Z still toggles either direction.")
            }

            Section("Workflow") {
                Toggle("Auto-advance after keyboard rating", isOn: $autoAdvance)
                    .help("When you use a keyboard shortcut (1–5, Shift+1–5, R) to set a star, label, or reject, jump to the next pair. Clearing a rating does not advance.")
                Toggle("Auto-advance after sidebar rating", isOn: $autoAdvanceSidebar)
                    .help("When you click a star, label dot, or the Reject button in the sidebar Decisions panel, jump to the next pair.")
                Picker("G rejects in burst", selection: $gRejectScopeRaw) {
                    ForEach(GRejectScope.allCases) { scope in
                        Text(scope.displayName).tag(scope.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .help("Behaviour of the G shortcut when you're inside a burst. \"Only unrated\" keeps your earlier ratings; \"All other\" rejects every member except the one you're on.")
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

            advancedCachesSection

            Section("Advanced — Display") {
                Toggle("Show loading spinner on canvas during nav", isOn: $showCanvasLoadingIndicator)
                    .help("Adds a small centred spinner over the image whenever the canvas is loading a different pair than the one you've navigated to. Off by default — most nav is fast enough that the spinner would just flash.")
            }
        }
        .formStyle(.grouped)
        .task {
            // Poll the (non-Observable) caches once per second while
            // Settings is open. .task auto-cancels on view disappear.
            while !Task.isCancelled {
                await refreshAdvancedStats()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onChange(of: textureCacheCapacity) { _, new in
            MTLTextureCache.shared.setCapacity(max(1, new))
        }
        .onChange(of: previewBytesCacheMB) { _, new in
            let pipeline = state.pipeline
            Task { await pipeline.previewBytes.setByteCapacity(max(1, new) * 1024 * 1024) }
        }
        // prefetchRadius is read at prefetch time, so no apply needed.
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

    // MARK: - Advanced: Caches & Prefetch

    /// Polled snapshot of every cache the Settings → Advanced panel
    /// displays. Updated by `refreshAdvancedStats()`.
    private struct AdvancedCacheStats {
        var textureCount: Int = 0
        var textureMeanBytes: Int = 0
        var previewCount: Int = 0
        var previewMeanBytes: Int = 0
        var previewBytesUsed: Int = 0
        var thumbnailCount: Int = 0
        var thumbnailMeanBytes: Int = 0
        var histogramCount: Int = 0
    }

    /// Fixed per-histogram footprint: 256 bins × 3 channels × Int.
    private static let histogramBytes = 256 * 3 * MemoryLayout<Int>.size

    private func refreshAdvancedStats() async {
        let tex = MTLTextureCache.shared.stats
        let pipeline = state.pipeline
        let prevCount = await pipeline.previewBytes.count
        let prevBytes = await pipeline.previewBytes.bytesUsed
        let prevMean  = prevCount > 0 ? prevBytes / prevCount : 0
        let thumbs    = state.thumbnails
        let thumbCount = thumbs.count
        let thumbMean: Int = {
            guard thumbCount > 0 else { return 0 }
            var total = 0
            // CGImage.bytesPerRow * height gives the actual decoded
            // raw size — what's actually retained per entry.
            for img in thumbs.values { total += img.bytesPerRow * img.height }
            return total / thumbCount
        }()
        let histCount = state.entryHistograms.count
        advancedStats = AdvancedCacheStats(
            textureCount: tex.count,
            textureMeanBytes: tex.meanTextureBytes,
            previewCount: prevCount,
            previewMeanBytes: prevMean,
            previewBytesUsed: prevBytes,
            thumbnailCount: thumbCount,
            thumbnailMeanBytes: thumbMean,
            histogramCount: histCount
        )
    }

    @ViewBuilder
    private var advancedCachesSection: some View {
        Section("Advanced — Caches & Prefetch") {
            // Texture cache
            LabeledContent("GPU texture cache") {
                HStack(spacing: 6) {
                    TextField("", value: $textureCacheCapacity, format: .number)
                        .frame(width: 70)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                    Text("entries").foregroundStyle(.secondary)
                }
            }
            cacheStatsRow(
                perItemLabel: "Per texture",
                perItemBytes: advancedStats.textureMeanBytes,
                perItemFallbackBytes: Self.fallbackTextureBytes,
                currentCount: advancedStats.textureCount,
                currentBytes: advancedStats.textureCount * advancedStats.textureMeanBytes,
                configMaxBytes: textureCacheCapacity * max(advancedStats.textureMeanBytes, Self.fallbackTextureBytes),
                configMaxIsEstimated: advancedStats.textureMeanBytes == 0
            )

            // Preview bytes cache
            LabeledContent("Preview bytes cache") {
                HStack(spacing: 6) {
                    TextField("", value: $previewBytesCacheMB, format: .number)
                        .frame(width: 70)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                    Text("MB").foregroundStyle(.secondary)
                }
            }
            cacheStatsRow(
                perItemLabel: "Avg HIF / JPG",
                perItemBytes: advancedStats.previewMeanBytes,
                perItemFallbackBytes: Self.fallbackPreviewBytes,
                currentCount: advancedStats.previewCount,
                currentBytes: advancedStats.previewBytesUsed,
                configMaxBytes: previewBytesCacheMB * 1024 * 1024
            )

            // Prefetch radius
            LabeledContent("Prefetch radius") {
                HStack(spacing: 6) {
                    TextField("", value: $prefetchRadius, format: .number)
                        .frame(width: 70)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                    Text("frames each side").foregroundStyle(.secondary)
                }
            }
            if prefetchRadius > 1 {
                Text("Wider than ±1 may contend with user nav uploads (observed +600 ms at ±2 in earlier testing on slower hardware).")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if prefetchRadius == 0 {
                Text("Prefetch disabled. Every nav into a fresh frame will hit the decoder + upload path.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Uncapped per-shoot caches — informational only
            DisclosureGroup("Per-shoot caches (uncapped)") {
                cacheStatsRow(
                    perItemLabel: "Avg thumbnail",
                    perItemBytes: advancedStats.thumbnailMeanBytes,
                    perItemFallbackBytes: Self.fallbackThumbBytes,
                    currentCount: advancedStats.thumbnailCount,
                    currentBytes: advancedStats.thumbnailCount * advancedStats.thumbnailMeanBytes,
                    configMaxBytes: nil
                )
                cacheStatsRow(
                    perItemLabel: "Histogram",
                    perItemBytes: Self.histogramBytes,
                    currentCount: advancedStats.histogramCount,
                    currentBytes: advancedStats.histogramCount * Self.histogramBytes,
                    configMaxBytes: nil
                )
            }

            // Total estimate
            totalsRow
        }
    }

    // Sony A1 II baselines used when the live caches are empty (no
    // shoot, or shoot just opened — caches still warming). Measured
    // from a real workflow; let the user see realistic projections
    // before they open anything.
    /// Decoded preview texture (8640 × 5760 × 4 BGRA, ×4/3 mipmaps).
    private static let fallbackTextureBytes = Int(253.1 * 1024 * 1024)
    /// Embedded HIF / JPG preview bytes per frame.
    private static let fallbackPreviewBytes = Int(5.8 * 1024 * 1024)
    /// Decoded thumbnail CGImage (160 × 120-ish RGBA).
    private static let fallbackThumbBytes   = 67 * 1024

    /// Three-line stats block under each cache widget. Per-item +
    /// current usage + (optionally) max-at-configured-cap.
    ///
    /// When `perItemBytes == 0` (cache empty: no shoot, or shoot just
    /// opened) but `perItemFallbackBytes > 0`, the per-item row shows
    /// the fallback with a "~ / est." marker so the user always sees
    /// a realistic projection. Same fallback flows into the
    /// configMax-estimated case.
    ///
    /// `configMaxIsEstimated` is false for caches like preview-bytes
    /// where the configured cap IS a literal byte budget independent
    /// of per-item size — no tilde needed there.
    @ViewBuilder
    private func cacheStatsRow(
        perItemLabel: String,
        perItemBytes: Int,
        perItemFallbackBytes: Int = 0,
        currentCount: Int,
        currentBytes: Int,
        configMaxBytes: Int?,
        configMaxIsEstimated: Bool = false
    ) -> some View {
        let perItemIsEstimated = perItemBytes == 0 && perItemFallbackBytes > 0
        let perItemDisplay = perItemBytes > 0 ? perItemBytes : perItemFallbackBytes
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(perItemLabel).foregroundStyle(.secondary)
                Spacer()
                if perItemDisplay > 0 {
                    let prefix = perItemIsEstimated ? "~" : ""
                    let suffix = perItemIsEstimated ? " (Sony A1 II est.)" : ""
                    Text("\(prefix)\(Self.formatBytes(perItemDisplay))\(suffix)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    Text("—").foregroundStyle(.secondary).monospacedDigit()
                }
            }
            HStack {
                Text("Currently using").foregroundStyle(.secondary)
                Spacer()
                Text("\(currentCount) entries / \(Self.formatBytes(currentBytes))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if let configMaxBytes {
                HStack {
                    Text("Max at config").foregroundStyle(.secondary)
                    Spacer()
                    let prefix = configMaxIsEstimated ? "~" : ""
                    let suffix = configMaxIsEstimated ? " (est., refines with open shoot)" : ""
                    Text("\(prefix)\(Self.formatBytes(configMaxBytes))\(suffix)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .font(.caption)
    }

    @ViewBuilder
    private var totalsRow: some View {
        let textureCurrent  = advancedStats.textureCount * advancedStats.textureMeanBytes
        let textureMax      = textureCacheCapacity * max(advancedStats.textureMeanBytes, Self.fallbackTextureBytes)
        let previewCurrent  = advancedStats.previewBytesUsed
        let previewMax      = previewBytesCacheMB * 1024 * 1024
        let thumbCurrent    = advancedStats.thumbnailCount * advancedStats.thumbnailMeanBytes
        let histCurrent     = advancedStats.histogramCount * Self.histogramBytes
        let totalCurrent    = textureCurrent + previewCurrent + thumbCurrent + histCurrent
        let totalMax        = textureMax + previewMax + thumbCurrent + histCurrent
        // Texture-projection uses a fallback per-item when the cache
        // is empty; reflect that in the totals so the user isn't
        // misled into thinking the projection is from live data.
        let maxIsEstimated  = advancedStats.textureMeanBytes == 0
        let prefix = maxIsEstimated ? "~" : ""
        let suffix = maxIsEstimated ? " (est.)" : ""
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Total memory estimate").bold()
                Spacer()
                Text("\(Self.formatBytes(totalCurrent)) current / \(prefix)\(Self.formatBytes(totalMax))\(suffix) at config max")
                    .monospacedDigit()
            }
            .font(.callout)
            Text("Per-shoot caches (thumbnails, histograms) are uncapped; their current value carries over to the projected max.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private static func formatBytes(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
}

#Preview {
    SettingsView()
}
