import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications

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

    // Indexer cache — see IndexerCache.swift. Toggles control which
    // datums get persisted per file. Max size caps the LRU GC.
    static let cacheExifSummary  = "settings.indexerCache.cacheExifSummary"
    static let cacheAFData       = "settings.indexerCache.cacheAFData"
    static let cacheSequence     = "settings.indexerCache.cacheSequence"
    static let cacheThumbnail    = "settings.indexerCache.cacheThumbnail"
    /// Max cache size in GIGABYTES (Int). Converted to bytes when
    /// pushed into IndexerCache.policy.maxTotalBytes.
    static let indexerCacheMaxSizeGB = "settings.indexerCache.maxSizeGB"

    // Privacy — opt-in telemetry. Counters always accumulate locally
    // (see UsageMetrics) and the stats window is always on; this gate
    // controls only whether the snapshot is uploaded to PostHog.
    /// Bool — default false. Flip in Settings -> Privacy.
    static let telemetryEnabled     = "settings.telemetryEnabled"
    /// String — random UUID generated lazily on first telemetry
    /// upload. Write-once for the lifetime of the install; never
    /// cleared by toggle-off or "Reset stats". A fresh ID requires
    /// `defaults delete dev.frostman.PhotoX settings.telemetryAnonymousID`
    /// (or an uninstall).
    static let telemetryAnonymousID = "settings.telemetryAnonymousID"

    /// Per-tab last-seen help-overlay version. The auto-show
    /// logic in `ModeWiring` triggers when a tab's declared
    /// `helpVersion` exceeds this stored value. Defaults to
    /// `0` for any tab the user has never visited (so the
    /// first ship of any tab — `helpVersion: 1` — auto-shows).
    ///
    /// **Stored in `LocalAppDefaults.shared`, not
    /// `AppDefaults.shared`** — dev and prod should track
    /// their own "seen" history so bumping `helpVersion` in
    /// one build doesn't silently mark the same tab
    /// already-seen in the other.
    static func helpLastSeen(for mode: WorkspaceMode) -> String {
        "help.lastSeenVersion.\(mode.rawValue)"
    }

    /// User's toggle for the background card watcher
    /// (`PhotoXCardWatcher` LaunchAgent). **Stored in
    /// `LocalAppDefaults.shared`, not `AppDefaults.shared`** —
    /// prod and dev register independent helpers, so the
    /// toggle must be per-bundle. Default off.
    static let cardWatcherEnabled = "settings.cardWatcherEnabled"

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
        static let telemetryEnabled     = false
        static let cacheExifSummary     = true
        static let cacheAFData          = true
        static let cacheSequence        = true
        static let cacheThumbnail       = true
        static let indexerCacheMaxSizeGB = 2
        static let cardWatcherEnabled    = false
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
    @AppStorage(SettingsKey.telemetryEnabled,     store: AppDefaults.shared) private var telemetryEnabled     = SettingsKey.Defaults.telemetryEnabled
    @AppStorage(SettingsKey.cacheExifSummary,     store: AppDefaults.shared) private var cacheExifSummary     = SettingsKey.Defaults.cacheExifSummary
    @AppStorage(SettingsKey.cacheAFData,          store: AppDefaults.shared) private var cacheAFData          = SettingsKey.Defaults.cacheAFData
    @AppStorage(SettingsKey.cacheSequence,        store: AppDefaults.shared) private var cacheSequence        = SettingsKey.Defaults.cacheSequence
    @AppStorage(SettingsKey.cacheThumbnail,       store: AppDefaults.shared) private var cacheThumbnail       = SettingsKey.Defaults.cacheThumbnail
    @AppStorage(SettingsKey.indexerCacheMaxSizeGB, store: AppDefaults.shared) private var indexerCacheMaxSizeGB = SettingsKey.Defaults.indexerCacheMaxSizeGB

    // Card-watcher toggle is per-bundle (LocalAppDefaults.shared,
    // not the cross-bundle AppDefaults). Prod and dev each register
    // their own LaunchAgent, so the toggle that drives
    // register/unregister must NOT be shared between builds.
    @AppStorage(SettingsKey.cardWatcherEnabled, store: LocalAppDefaults.shared) private var cardWatcherEnabled = SettingsKey.Defaults.cardWatcherEnabled

    /// Last error from a card-watcher register/unregister attempt
    /// — surfaces inline under the toggle so the user knows when
    /// macOS rejected the action (typically: Login Items
    /// permission not granted yet).
    @State private var cardWatcherError: String? = nil

    /// Cached live status for the card watcher.
    /// `SMAppService.status` isn't `@Observable` and doesn't
    /// update synchronously on register / unregister, so we
    /// poll it (alongside the cache stats) every second and
    /// also refresh immediately after toggle actions.
    @State private var cardWatcherStatus: CardWatcherSupervisor.LiveStatus = .notRegistered

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

            Section("Indexer cache") {
                Toggle("Cache basic EXIF",            isOn: $cacheExifSummary)
                Toggle("Cache AF data",                isOn: $cacheAFData)
                Toggle("Cache burst sequence numbers", isOn: $cacheSequence)
                Toggle("Cache thumbnail bytes",        isOn: $cacheThumbnail)
                Stepper(value: $indexerCacheMaxSizeGB, in: 1 ... 50) {
                    Text("Max cache size: \(indexerCacheMaxSizeGB) GB")
                }
                HStack {
                    Text("Current size: \(Self.formatBytes(Int(advancedStats.indexerCacheBytes)))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear all caches") {
                        IndexerCache.deleteAllCaches()
                    }
                }
                Text("Cached per file: basic EXIF (~500 B), AF data (~1.5 KB), sequence number (8 B), embedded thumbnail JPEG (~8 KB). Histograms are NOT cached — computed lazily on first sidebar view. Files larger than the max size are LRU-evicted whole-shoot.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Card watcher") {
                Toggle("Watch for camera cards in the background", isOn: $cardWatcherEnabled)
                    .help("When enabled, a tiny background helper monitors for SD / CFExpress card mounts even while PhotoX is closed and posts a notification to open the card in PhotoX with a single click.")
                    .onChange(of: cardWatcherEnabled) { _, enabled in
                        Task { await applyCardWatcherToggle(enabled: enabled) }
                    }
                cardWatcherStatusLine
                if let err = cardWatcherError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Text("Helper runs as a LaunchAgent registered via SMAppService. It's installed inside the PhotoX app bundle, registered only when this toggle is on, and shows up in System Settings → Login Items where you can also disable it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Privacy") {
                Toggle("Send anonymous usage stats to PostHog Cloud", isOn: $telemetryEnabled)
                    .help("Off by default. When on, PhotoX uploads the same integer counters shown in Window → Usage Stats… every \(TelemetryConfig.uploadIntervalDescription) and on quit. Toggle off any time.")
                Text("Only the counters (app opens, photos seen, ratings/labels set, shoots opened, exports run, images exported) and a random anonymous ID leave your device. No filenames, ratings values, photos, EXIF, or paths are ever sent. The anonymous ID is generated the first time you opt in and persists for the life of the install so stats stitch across toggle-off/on cycles. Counters are always saved locally every \(TelemetryConfig.localPersistIntervalDescription) regardless of this toggle.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            // Poll the (non-Observable) caches + the card-watcher
            // SMAppService status once per second while Settings
            // is open. .task auto-cancels on view disappear.
            refreshCardWatcherStatus()
            while !Task.isCancelled {
                await refreshAdvancedStats()
                refreshCardWatcherStatus()
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
        .onChange(of: cacheExifSummary)      { _, new in IndexerCache.policy.cacheExifSummary  = new }
        .onChange(of: cacheAFData)            { _, new in IndexerCache.policy.cacheAFData       = new }
        .onChange(of: cacheSequence)          { _, new in IndexerCache.policy.cacheSequence     = new }
        .onChange(of: cacheThumbnail)         { _, new in IndexerCache.policy.cacheThumbnail    = new }
        .onChange(of: indexerCacheMaxSizeGB)  { _, new in
            IndexerCache.policy.maxTotalBytes = Int64(new) * 1024 * 1024 * 1024
            IndexerCache.gcIfNeeded()
        }
        .onChange(of: telemetryEnabled) { _, newValue in
            // Toggle ON: fire an immediate flush so the user sees an
            // event land in PostHog without waiting a full
            // `TelemetryConfig.uploadInterval` for the periodic
            // loop. Toggle OFF: nothing to do — the next periodic
            // tick gates on the setting and stays quiet.
            guard newValue else { return }
            Task { await state.uploadTelemetryNow() }
        }
        // prefetchRadius is read at prefetch time, so no apply needed.
        .frame(width: 620, height: 660)
        .navigationTitle("PhotoX Settings")
        // Esc closes the Settings window. SwiftUI's Settings scene
        // doesn't wire `.dismiss` (no responder-chain dismiss), so
        // route through AppKit by performing the standard close on
        // the key window. Hidden 0x0 button keeps it out of layout
        // and accessibility — same pattern as StatsView.
        .background {
            Button("") {
                NSApp.keyWindow?.performClose(nil)
            }
            .keyboardShortcut(.cancelAction)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
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
        /// Sum of every `.plist` under the on-disk indexer
        /// cache root. Populated off-main by
        /// `refreshAdvancedStats` so the directory walk
        /// never stalls the Settings UI.
        var indexerCacheBytes: Int64 = 0
    }

    /// Fixed per-histogram footprint: 256 bins × 3 channels × Int.
    private static let histogramBytes = 256 * 3 * MemoryLayout<Int>.size

    // MARK: - Card watcher helpers

    /// Same filename in every config — the LaunchAgent plist
    /// is copied into Contents/Library/LaunchAgents/CardWatcher.plist
    /// by the main app's post-compile script (with per-config
    /// build-setting substitution applied to the contents).
    private static let cardWatcherPlistName = "CardWatcher.plist"

    /// Status line under the card-watcher toggle. Reflects the
    /// LaunchAgent's current state per SMAppService so the user
    /// can see when macOS is waiting for approval. Reads the
    /// cached `cardWatcherStatus` (refreshed by `.task` + after
    /// every toggle action) rather than calling SMAppService
    /// directly, so the line re-renders as the OS catches up.
    @ViewBuilder
    private var cardWatcherStatusLine: some View {
        switch cardWatcherStatus {
        case .running(let pid):
            Text("Status: running (pid \(pid))")
                .font(.caption)
                .foregroundStyle(.green)
        case .registeredNotRunning:
            HStack(spacing: 6) {
                Text("Status: registered but not running")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Button("Restart") {
                    Task {
                        await CardWatcherSupervisor.manualRestart()
                        await MainActor.run { refreshCardWatcherStatus() }
                    }
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        case .spawnFailed(let code):
            // macOS refuses to spawn the helper — usually a
            // stale BTM/LWCR record after the helper binary's
            // code-signing identity changed across rebuilds.
            // SMAppService can't clear this cache; only the
            // user toggling the helper off+on in System
            // Settings → Login Items can.
            VStack(alignment: .leading, spacing: 4) {
                Text("Status: blocked by macOS (exit \(code))")
                    .font(.caption)
                    .foregroundStyle(.red)
                Text("Open Login Items, toggle PhotoX off then back on, then click Restart here.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Open Login Items") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    Button("Restart") {
                        Task {
                            await CardWatcherSupervisor.manualRestart()
                            await MainActor.run { refreshCardWatcherStatus() }
                        }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
        case .requiresApproval:
            HStack(spacing: 6) {
                Text("Status: needs approval in System Settings → Login Items")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Button("Open") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        case .notRegistered:
            Text("Status: stopped")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .unknown:
            Text("Status: unknown")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Toggle → register/unregister the LaunchAgent via SMAppService
    /// and (on enable) request notification permission. Surfaces
    /// any error inline via `cardWatcherError`. Failures roll the
    /// toggle back so the persisted state matches reality.
    @MainActor
    private func applyCardWatcherToggle(enabled: Bool) async {
        cardWatcherError = nil
        let service = SMAppService.agent(plistName: Self.cardWatcherPlistName)
        if enabled {
            do {
                try service.register()
            } catch {
                cardWatcherError = "Couldn't register helper: \(error.localizedDescription)"
                cardWatcherEnabled = false
                refreshCardWatcherStatus()
                return
            }
        } else {
            do {
                try await service.unregister()
            } catch {
                cardWatcherError = "Couldn't unregister helper: \(error.localizedDescription)"
                cardWatcherEnabled = true
            }
        }
        // The OS takes a beat to flip status after
        // register/unregister; refresh now, then again after a
        // short delay so the status line shows the correct
        // value even if the first read is still stale.
        refreshCardWatcherStatus()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            refreshCardWatcherStatus()
        }
    }

    @MainActor
    private func refreshCardWatcherStatus() {
        // liveStatus runs `launchctl print` off the main
        // thread; we just hop back to MainActor to assign
        // the @State once it's ready.
        Task {
            let status = await CardWatcherSupervisor.liveStatus()
            await MainActor.run { cardWatcherStatus = status }
        }
    }

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
        // Cheap (a few-KB plist per shoot, low hundreds of
        // entries even on power users) so staying on
        // MainActor here is fine — `totalSize()` itself is
        // MainActor-isolated because `rootDirectory` reads
        // a static override slot.
        let indexerBytes = IndexerCache.totalSize()
        advancedStats = AdvancedCacheStats(
            textureCount: tex.count,
            textureMeanBytes: tex.meanTextureBytes,
            previewCount: prevCount,
            previewMeanBytes: prevMean,
            previewBytesUsed: prevBytes,
            thumbnailCount: thumbCount,
            thumbnailMeanBytes: thumbMean,
            histogramCount: histCount,
            indexerCacheBytes: indexerBytes
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
