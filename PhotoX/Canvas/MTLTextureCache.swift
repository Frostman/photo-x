import CoreGraphics
import Foundation
@preconcurrency import Metal
import MetalKit

/// Shared GPU-texture cache. Sits at the END of the decode pipeline —
/// once a `DecodedImage` has been uploaded to a Metal texture, the
/// CGImage isn't needed anymore for display. Caching here makes
/// back-and-forth A↔B↔A↔B navigation near-instant: cache hit returns
/// a ready-to-bind `MTLTexture` synchronously.
///
/// Replaces the old `DecodedImageCache` (decoded CGImages) — texture
/// IS the displayable artifact, so we cache that instead and skip a
/// duplicated CPU-side copy. The 30 ms re-decode cost on revisits
/// (HEIF bytes are still in HIFBytesCache; ImageIO decode is fast) is
/// the trade-off; prefetch (Part 3) drives `warm(...)` so neighbours
/// land in the cache before the user navigates to them.
///
/// **Concurrency model**: MainActor-isolated for cache lookup so the
/// hit path is synchronous and racy out-of-actor reads can't happen.
/// The actual texture upload (`MTKTextureLoader.newTexture`) runs off
/// the main actor inside a `Task.detached`; the result hops back to
/// MainActor for insert. Single-flight `inflight` dict dedupes
/// concurrent `warm(...)` calls for the same key.
///
/// **Eviction**: insertion-order LRU at 20 entries (~200 MB / entry in
/// unified memory). Eviction drops the texture reference; Metal
/// releases the GPU memory automatically when no strong references
/// remain. The currently-bound texture in `CanvasRenderer.baseTexture`
/// keeps that texture alive even after cache eviction — the cache
/// merely loses its ability to serve the next request from RAM.
@MainActor
final class MTLTextureCache {
    /// Process-wide singleton. There's only ever one canvas-bound GPU
    /// texture cache in PhotoX; making it a singleton avoids plumbing
    /// the reference through the SwiftUI view tree.
    static let shared = MTLTextureCache()

    struct Entry: Sendable {
        let texture: MTLTexture
        /// Display-orientation pixel size (W↔H swapped for orientations
        /// 5–8). Stored so cache consumers don't have to re-derive it.
        let pixelSize: CGSize
        let orientation: Int
    }

    let device: MTLDevice
    private let textureLoader: MTKTextureLoader
    /// Dedicated command queue for the mipmap-generation blit at the
    /// end of each upload. Sharing with the renderer's queue would be
    /// fine too; a dedicated one avoids any cross-actor contention.
    private let commandQueue: MTLCommandQueue

    private var entries: [DecodeKey: Entry] = [:]
    /// Insertion order, MRU at the end. Eviction pops from the front.
    private var order: [DecodeKey] = []
    private var inflight: [DecodeKey: Task<Entry, Error>] = [:]
    private let capacity: Int

    private init(capacity: Int = 20) {
        // Fail loudly if no Metal device — this is the same path the
        // existing CanvasRenderer.init takes, but earlier in startup.
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("MTLTextureCache: no Metal device available")
        }
        guard let queue = device.makeCommandQueue() else {
            fatalError("MTLTextureCache: no Metal command queue")
        }
        self.device = device
        self.textureLoader = MTKTextureLoader(device: device)
        self.commandQueue = queue
        self.capacity = capacity
    }

    /// Synchronous cache lookup. Returns nil if not present; bumps the
    /// hit entry to MRU on the way out.
    @discardableResult
    func get(_ key: DecodeKey) -> Entry? {
        guard let entry = entries[key] else { return nil }
        bumpMRU(key)
        return entry
    }

    /// Upload `cgImage` into a Metal texture if it isn't already cached,
    /// and return the cached `Entry`. Concurrent calls for the same key
    /// share a single upload via the `inflight` dict.
    func warm(cgImage: CGImage, key: DecodeKey, orientation: Int) async throws -> Entry {
        if let cached = get(key) { return cached }
        if let existing = inflight[key] {
            return try await existing.value
        }

        let loader = textureLoader
        let queue = commandQueue
        let task = Task.detached(priority: .userInitiated) { () -> Entry in
            let texture = try Self.uploadTexture(cgImage: cgImage, loader: loader, commandQueue: queue)
            let isSwapped = orientation >= 5 && orientation <= 8
            let pixelSize: CGSize = isSwapped
                ? CGSize(width: cgImage.height, height: cgImage.width)
                : CGSize(width: cgImage.width, height: cgImage.height)
            return Entry(texture: texture, pixelSize: pixelSize, orientation: orientation)
        }
        inflight[key] = task

        do {
            let entry = try await task.value
            inflight[key] = nil
            insert(key, entry)
            return entry
        } catch {
            inflight[key] = nil
            throw error
        }
    }

    /// Drop everything. Called on shoot switch — old shoot's textures
    /// shouldn't outlive the shoot. In-flight uploads are intentionally
    /// NOT cancelled (MTKTextureLoader doesn't honor Task cancellation
    /// at a granular level); they'll resolve and clean themselves up.
    func clear() {
        entries.removeAll()
        order.removeAll()
    }

    /// Test/diagnostic — current entry count.
    var count: Int { entries.count }

    // MARK: - internals

    private func bumpMRU(_ key: DecodeKey) {
        if let idx = order.firstIndex(of: key) {
            order.remove(at: idx)
            order.append(key)
        }
    }

    private func insert(_ key: DecodeKey, _ entry: Entry) {
        if entries[key] != nil {
            // Re-insert: drop old position, append fresh at MRU.
            order.removeAll { $0 == key }
        }
        entries[key] = entry
        order.append(key)
        while order.count > capacity {
            let evict = order.removeFirst()
            entries.removeValue(forKey: evict)
        }
    }

    /// MTKTextureLoader fails with "Image decoding failed" on a lot
    /// of ImageIO-produced HEIF CGImages, AND the
    /// materialise-into-BGRA8 workaround double-encodes gamma on
    /// Apple Silicon (image renders too bright). So we just use a
    /// manual CGContext path: render → texture.replace → mipmap blit.
    /// Same algorithm the canvas previously used inline as a
    /// fallback, with correct colours.
    private nonisolated static func uploadTexture(cgImage: CGImage,
                                                    loader: MTKTextureLoader,
                                                    commandQueue: MTLCommandQueue) throws -> MTLTexture
    {
        let device = loader.device
        _ = loader   // silence unused — kept for symmetry / future switch back
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = width * 4

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw TextureError.contextCreationFailed
        }
        let bitmapInfo: UInt32 = CGImageAlphaInfo.premultipliedFirst.rawValue
                               | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ), let dataPtr = context.data else {
            throw TextureError.contextCreationFailed
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: width,
            height: height,
            mipmapped: true
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw TextureError.textureCreationFailed
        }
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: dataPtr,
            bytesPerRow: bytesPerRow
        )
        if let cmd = commandQueue.makeCommandBuffer(),
           let blit = cmd.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
            cmd.commit()
        }
        return texture
    }

    enum TextureError: Error {
        case contextCreationFailed
        case textureCreationFailed
    }
}
