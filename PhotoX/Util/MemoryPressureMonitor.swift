import AppKit
import Dispatch
import OSLog

/// Listens to the kernel's memory-pressure source and shrinks the
/// app's two big LRU caches when the system asks. Both caches are
/// process-wide so this monitor doesn't need per-window logic — an
/// idle window's entries sit at the LRU tail by definition and get
/// evicted first when caps shrink.
///
/// Pressure levels:
/// - `.normal`   → restore the user-configured caps from Settings.
/// - `.warning`  → halve both caps.
/// - `.critical` → drop to a quarter.
///
/// Started once from `AppDelegate.applicationDidFinishLaunching`.
@MainActor
final class MemoryPressureMonitor {
    static let shared = MemoryPressureMonitor()
    private init() {}

    private var source: DispatchSourceMemoryPressure?

    func start() {
        guard source == nil else { return }
        let s = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical, .normal],
            queue: .main)
        s.setEventHandler { [weak self] in
            // setEventHandler closure isn't statically MainActor;
            // queue: .main guarantees we're on the main thread.
            MainActor.assumeIsolated {
                self?.handle(s.data)
            }
        }
        s.resume()
        source = s
        Log.app.notice("MemoryPressureMonitor started")
    }

    private func handle(_ event: DispatchSource.MemoryPressureEvent) {
        let textureBaseline = configuredTextureCapacity()
        let previewBaseline = PreviewBytesCache.capacityFromDefaults()

        let (textureCap, previewCap, label): (Int, Int, String)
        if event.contains(.critical) {
            textureCap = max(1, textureBaseline / 4)
            previewCap = max(1, previewBaseline / 4)
            label = "critical"
        } else if event.contains(.warning) {
            textureCap = max(1, textureBaseline / 2)
            previewCap = max(1, previewBaseline / 2)
            label = "warning"
        } else {
            // .normal — pressure has lifted, restore baselines.
            textureCap = textureBaseline
            previewCap = previewBaseline
            label = "normal"
        }

        // Logged on the cache category so it sits with the other
        // cache-cap mutations (setCapacity / setByteCapacity).
        // `.notice` rather than `.warning` because OSLog's "warning"
        // level is actually `.error` under the hood and would look
        // alarming in Console for a routine cap-shrink.
        Log.cache.notice("memoryPressure=\(label, privacy: .public) → textureCap=\(textureCap) previewCapMB=\(previewCap / (1024 * 1024))")
        MTLTextureCache.shared.setCapacity(textureCap)
        Task { await PreviewBytesCache.shared.setByteCapacity(previewCap) }
    }

    private func configuredTextureCapacity() -> Int {
        let stored = AppDefaults.shared.object(forKey: SettingsKey.textureCacheCapacity) as? Int
        return max(1, stored ?? SettingsKey.Defaults.textureCacheCapacity)
    }
}
