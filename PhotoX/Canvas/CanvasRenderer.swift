import CoreGraphics
import Metal
import MetalKit
import QuartzCore

@MainActor
final class CanvasRenderer {
    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    /// Shared GPU-texture cache; reused across the whole canvas. Cache
    /// HITs swap `baseTexture` synchronously (back-and-forth nav feels
    /// instant). MISSes go through the coalesced async upload path
    /// below.
    private let textureCache: MTLTextureCache

    private var baseTexture: MTLTexture?
    /// DISPLAY-orientation pixel size (i.e. dimensions AFTER EXIF
    /// rotation has been notionally applied). The raw texture is laid
    /// out in sensor orientation; we swap W↔H for portrait shots so
    /// viewport math (fit, 1:1, gestures) operates in display space.
    private var imagePixelSize: CGSize = .zero
    /// EXIF orientation (1–8) of the currently-bound texture. Used
    /// only inside `quadVertices` to emit the right UV mapping —
    /// the shader itself is orientation-agnostic.
    private var imageOrientation: Int = 1
    private var viewport: CanvasViewport = .identity
    private var showClipping: Bool = false
    private var showPeaking: Bool = false
    private var peakingThreshold: Float = 0.15

    /// Monotonic generation counter — bumped on every `setImage`. Each
    /// detached load captures its own gen; completions display only
    /// when their gen is newer than what's already on screen. This way
    /// a fast burst of nav events (← held down) doesn't drop every
    /// intermediate frame — the canvas catches up as each load
    /// completes instead of looking frozen until the user stops.
    private var loadGeneration: Int = 0

    /// The highest generation that has been committed to `baseTexture`.
    /// Out-of-order completions older than this are dropped (the canvas
    /// already shows something newer).
    private var displayedGeneration: Int = 0

    /// Coalescing state for cache MISSes: at most one upload is in
    /// flight + one pending. A held arrow key that fires `setImage`
    /// 50 times only spawns one upload at a time — the latest pending
    /// supersedes earlier ones, so the GPU only does ONE intermediate
    /// upload + the final one rather than 50 in parallel.
    private struct PendingRequest {
        let cgImage: CGImage
        let key: DecodeKey
        let token: String
        let orientation: Int
        let gen: Int
    }
    private var inFlight: Bool = false
    private var pendingRequest: PendingRequest?

    /// Called on the main actor after an async texture load completes
    /// and `baseTexture` has been updated. Payload is:
    /// - `token`: the opaque string the caller passed to `setImage`
    ///   (PhotoX uses the pair's stem, so it can update its own
    ///   "displayed pair" state in lock-step with the bound texture).
    /// - `pixelSize`: the new image's pixel dimensions so the NSView
    ///   can update its own imagePixelSize without a glitch frame.
    var onTextureReady: ((_ token: String, _ pixelSize: CGSize) -> Void)?

    private struct FragmentUniforms {
        var showClipping: Int32
        var showPeaking: Int32
        var peakingThreshold: Float
    }

    init?(layerPixelFormat: MTLPixelFormat) {
        // Pull the device from the shared texture cache so both layers
        // operate on the same MTLDevice (mandatory: textures from one
        // device can't be sampled by another).
        let cache = MTLTextureCache.shared
        let device = cache.device
        guard let queue = device.makeCommandQueue(),
              let library = try? device.makeDefaultLibrary(bundle: .main),
              let vertexFn = library.makeFunction(name: "vertex_main"),
              let fragmentFn = library.makeFunction(name: "fragment_main")
        else {
            Log.canvas.error("CanvasRenderer init failed: device/queue/library setup")
            return nil
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFn
        descriptor.fragmentFunction = fragmentFn
        descriptor.colorAttachments[0].pixelFormat = layerPixelFormat
        descriptor.colorAttachments[0].isBlendingEnabled = false

        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else {
            Log.canvas.error("CanvasRenderer init failed: pipeline state")
            return nil
        }

        self.device = device
        self.commandQueue = queue
        self.pipelineState = pipeline
        self.textureCache = cache
    }

    /// Bind a Metal texture for `cgImage` and update the canvas. Two
    /// paths:
    ///
    /// 1. **Cache HIT** (`textureCache.get(key) != nil`): synchronous
    ///    bind. Bumps `loadGeneration` and `displayedGeneration`, swaps
    ///    the bound texture + display geometry, clears any pending
    ///    async upload (otherwise a stale pending warm would overwrite
    ///    this cached image later), and fires `onTextureReady`
    ///    immediately. NSView's `onTextureReady` handler still uses
    ///    the 1-runloop Metal-commit defer (same as the async path) so
    ///    SwiftUI's AFPointOverlay re-render lands in the same
    ///    CATransaction as the new Metal present — no "new image +
    ///    old AF" intermediate frame.
    /// 2. **Cache MISS**: coalesced async upload. If nothing is in
    ///    flight, kicks off `textureCache.warm(...)`. If something is
    ///    already in flight, stores the request as `pendingRequest` so
    ///    only the latest queued request actually completes — a fast
    ///    arrow-key burst no longer floods the GPU with N parallel
    ///    uploads.
    ///
    /// The previous bound texture stays visible until the new one is
    /// ready (no flash to black during the upload window).
    /// `onTextureReady` fires on the main actor when the new texture
    /// is bound (cache-hit fires immediately; cache-miss fires after
    /// the upload commits).
    func setImage(_ cgImage: CGImage, token: String, orientation: Int, key: DecodeKey) {
        PerfTracker.mark("CanvasRenderer.setImage entered")
        loadGeneration += 1
        let gen = loadGeneration

        // Cache HIT — synchronous bind, no async dance.
        if let cached = textureCache.get(key) {
            // Drop any pending warm queued while a previous upload was
            // in flight — that pending was for an even-older request
            // chain and would overwrite this cache-hit image later.
            pendingRequest = nil
            displayedGeneration = gen
            baseTexture = cached.texture
            imagePixelSize = cached.pixelSize
            imageOrientation = cached.orientation
            PerfTracker.mark("CanvasRenderer.setImage done (cache hit)")
            onTextureReady?(token, cached.pixelSize)
            return
        }

        // Cache MISS — queue an async warm. If something is already in
        // flight, store this request; the in-flight completion handler
        // will pick it up and supersede whatever's pending.
        let req = PendingRequest(cgImage: cgImage, key: key, token: token,
                                  orientation: orientation, gen: gen)
        if inFlight {
            pendingRequest = req
            return
        }
        startWarm(req)
    }

    /// Kick off the actual async upload for `req`. Assumes `inFlight`
    /// is false; sets it true. On completion, either commits the
    /// result OR consumes a newer `pendingRequest` and restarts.
    private func startWarm(_ req: PendingRequest) {
        inFlight = true
        let cache = textureCache
        let queue = commandQueue
        Task.detached(priority: .userInitiated) {
            let entry: MTLTextureCache.Entry?
            do {
                entry = try await cache.warm(cgImage: req.cgImage,
                                              key: req.key,
                                              orientation: req.orientation)
            } catch {
                // Fall back to a manual CGContext + replace upload. The
                // result isn't inserted into the cache (the cache's
                // own error path already returned nil), so a repeat
                // visit will retry — acceptable for the rare CGImage
                // format MTKTextureLoader rejects.
                Log.canvas.error("MTLTextureCache.warm failed (\(String(describing: error), privacy: .public)); falling back to manual upload")
                let device = cache.device
                let texture = Self.manualUpload(cgImage: req.cgImage,
                                                 device: device,
                                                 commandQueue: queue)
                let isSwapped = req.orientation >= 5 && req.orientation <= 8
                let pixelSize: CGSize = isSwapped
                    ? CGSize(width: req.cgImage.height, height: req.cgImage.width)
                    : CGSize(width: req.cgImage.width, height: req.cgImage.height)
                entry = texture.map {
                    MTLTextureCache.Entry(texture: $0, pixelSize: pixelSize,
                                          orientation: req.orientation)
                }
            }

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.inFlight = false

                // If a newer request queued while we were uploading,
                // DROP this result and kick off the pending one. The
                // intermediate texture is wasted GPU work, but it's
                // already done and the next iteration of the coalesce
                // loop bounds us at 1 in-flight + 1 pending.
                if let next = self.pendingRequest {
                    self.pendingRequest = nil
                    self.startWarm(next)
                    return
                }

                // Defence in depth: out-of-order completion (this load's
                // gen is older than something already displayed) — drop.
                guard req.gen > self.displayedGeneration else { return }
                guard let entry else {
                    Log.canvas.error("setImage: texture creation returned nil for \(req.cgImage.width)x\(req.cgImage.height)")
                    return
                }
                self.displayedGeneration = req.gen
                self.baseTexture = entry.texture
                self.imagePixelSize = entry.pixelSize
                self.imageOrientation = entry.orientation
                PerfTracker.mark("CanvasRenderer.setImage done (async)")
                self.onTextureReady?(req.token, entry.pixelSize)
            }
        }
    }

    /// Fallback path. Same algorithm as the original synchronous
    /// `makeTexture` (CGContext rasterise → `replace` into MTLTexture →
    /// mipmap blit) but runs off the main actor inside the detached
    /// task that called us. Used only when MTKTextureLoader throws,
    /// which can happen for unusual CGImage formats.
    private nonisolated static func manualUpload(cgImage: CGImage,
                                                  device: MTLDevice,
                                                  commandQueue: MTLCommandQueue) -> MTLTexture?
    {
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = width * 4

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
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
            return nil
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
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }

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

    func setViewport(_ viewport: CanvasViewport) {
        self.viewport = viewport
    }

    func setShowClipping(_ on: Bool) {
        self.showClipping = on
    }

    func setShowPeaking(_ on: Bool) {
        self.showPeaking = on
    }

    func draw(in layer: CAMetalLayer) {
        guard let baseTexture else {
            drawClear(in: layer)
            return
        }
        PerfTracker.mark("CanvasRenderer.draw entered")

        let drawableSize = layer.drawableSize
        guard drawableSize.width > 0, drawableSize.height > 0,
              let drawable = layer.nextDrawable() else { return }
        PerfTracker.mark("nextDrawable acquired")

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 1.0)
        pass.colorAttachments[0].storeAction = .store

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass)
        else { return }

        let vertices = quadVertices(drawableSize: drawableSize)
        let bufferLength = MemoryLayout<SIMD4<Float>>.stride * vertices.count
        vertices.withUnsafeBytes { ptr in
            encoder.setVertexBytes(ptr.baseAddress!, length: bufferLength, index: 0)
        }

        var fragmentUniforms = FragmentUniforms(
            showClipping: showClipping ? 1 : 0,
            showPeaking: showPeaking ? 1 : 0,
            peakingThreshold: peakingThreshold
        )
        encoder.setFragmentBytes(&fragmentUniforms,
                                  length: MemoryLayout<FragmentUniforms>.stride,
                                  index: 0)

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentTexture(baseTexture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
        PerfTracker.mark("commandBuffer committed + present")
    }

    private func drawClear(in layer: CAMetalLayer) {
        guard let drawable = layer.nextDrawable() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 1.0)
        pass.colorAttachments[0].storeAction = .store
        guard let cmd = commandQueue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }

    /// Build 6 vertices (2 triangles) for the image quad, positioned in clip space
    /// according to the current viewport. Each vertex is (x, y, u, v) packed into a SIMD4.
    /// UV mapping picks up `imageOrientation` so the GPU does the EXIF
    /// rotation via texture-coordinate transform — no CPU pixel
    /// rotation needed.
    private func quadVertices(drawableSize: CGSize) -> [SIMD4<Float>] {
        let fit = CanvasViewport.fitScale(imagePixelSize: imagePixelSize, viewPixelSize: drawableSize)
        let effectiveScale = fit * viewport.scale

        let imageDeviceWidth = imagePixelSize.width * effectiveScale
        let imageDeviceHeight = imagePixelSize.height * effectiveScale

        // Convert to clip space: x_clip = (2 * (px + drawableW/2) / drawableW) - 1.
        // With centered image and offset in device pixels:
        let halfW = Float(imageDeviceWidth / drawableSize.width)
        let halfH = Float(imageDeviceHeight / drawableSize.height)
        let ox = Float(2 * viewport.offset.x / drawableSize.width)
        let oy = Float(2 * viewport.offset.y / drawableSize.height)

        let left  = -halfW + ox
        let right =  halfW + ox
        // Metal's clip space y is up; CGImage memory layout has origin top-left.
        // We flip V to compensate so the image appears right-side-up.
        let bottom = -halfH + oy
        let top    =  halfH + oy

        // Pick the UV for each display-quad corner based on EXIF
        // orientation. `tl/tr/bl/br` are texture-space (u, v) — same
        // for orientation 1 as the original hard-coded mapping.
        let (tl, tr, bl, br) = uvCorners(for: imageOrientation)

        return [
            SIMD4(left,  bottom, bl.x, bl.y),
            SIMD4(right, bottom, br.x, br.y),
            SIMD4(left,  top,    tl.x, tl.y),
            SIMD4(right, bottom, br.x, br.y),
            SIMD4(right, top,    tr.x, tr.y),
            SIMD4(left,  top,    tl.x, tl.y)
        ]
    }

    /// EXIF orientation → texture-coordinate corners.
    /// Returned tuple is (topLeft, topRight, bottomLeft, bottomRight)
    /// where each corner names a position on the DISPLAY quad and the
    /// SIMD2 value is the UV to sample from the (sensor-orientation)
    /// texture at that display corner. Working through one example:
    /// orientation 6 (rotate 90° CW for display) — display top-left
    /// shows what was sensor bottom-left, so its UV is (0, 1); display
    /// top-right shows sensor top-left = (0, 0); and so on.
    private func uvCorners(for orientation: Int)
        -> (tl: SIMD2<Float>, tr: SIMD2<Float>, bl: SIMD2<Float>, br: SIMD2<Float>)
    {
        let uv: (Float, Float) -> SIMD2<Float> = { SIMD2($0, $1) }
        switch orientation {
        case 2:   // Mirror H
            return (uv(1, 0), uv(0, 0), uv(1, 1), uv(0, 1))
        case 3:   // Rotate 180
            return (uv(1, 1), uv(0, 1), uv(1, 0), uv(0, 0))
        case 4:   // Mirror V
            return (uv(0, 1), uv(1, 1), uv(0, 0), uv(1, 0))
        case 5:   // Transpose (mirror across main diagonal)
            return (uv(0, 0), uv(0, 1), uv(1, 0), uv(1, 1))
        case 6:   // Rotate 90 CW
            return (uv(0, 1), uv(0, 0), uv(1, 1), uv(1, 0))
        case 7:   // Transverse
            return (uv(1, 1), uv(1, 0), uv(0, 1), uv(0, 0))
        case 8:   // Rotate 90 CCW
            return (uv(1, 0), uv(1, 1), uv(0, 0), uv(0, 1))
        default:  // 1 = no transform (and any unexpected value)
            return (uv(0, 0), uv(1, 0), uv(0, 1), uv(1, 1))
        }
    }
}
