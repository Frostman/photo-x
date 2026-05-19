import CoreGraphics
import Metal
import MetalKit
import QuartzCore

@MainActor
final class CanvasRenderer {
    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let textureLoader: MTKTextureLoader

    private var baseTexture: MTLTexture?
    private var imagePixelSize: CGSize = .zero
    private var viewport: CanvasViewport = .identity
    private var showClipping: Bool = false
    private var showPeaking: Bool = false
    private var peakingThreshold: Float = 0.15

    /// Generation counter for the async texture loader. Bumped on every
    /// `setImage`; completions whose captured gen ≠ current are dropped
    /// so a fast burst of nav events doesn't see stale frames.
    private var loadGeneration: Int = 0

    /// Called on the main actor after an async texture load completes
    /// and `baseTexture` has been updated. Payload is the pixel size of
    /// the newly-loaded image so the NSView can update its own
    /// imagePixelSize in lock-step (avoids a glitch frame where the
    /// previous image is drawn at the new image's dimensions).
    var onTextureReady: ((CGSize) -> Void)?

    private struct FragmentUniforms {
        var showClipping: Int32
        var showPeaking: Int32
        var peakingThreshold: Float
    }

    init?(layerPixelFormat: MTLPixelFormat) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
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
        self.textureLoader = MTKTextureLoader(device: device)
    }

    /// Kick off an async load of `cgImage` into a Metal texture. The
    /// previous texture stays bound (and visible) until the new one is
    /// ready, so arrow-key navigation stays responsive even while the
    /// upload is in flight. Stale loads (a newer setImage came in
    /// before this one finished) are dropped via the generation counter.
    /// Reads to follow up:
    /// `onTextureReady` fires on the main actor when `baseTexture` has
    /// been updated.
    func setImage(_ cgImage: CGImage) {
        PerfTracker.mark("CanvasRenderer.setImage entered")
        loadGeneration += 1
        let gen = loadGeneration
        let pixelSize = CGSize(width: cgImage.width, height: cgImage.height)
        let loader = textureLoader
        let queue = commandQueue

        Task.detached(priority: .userInitiated) {
            // MTKTextureLoader handles format conversion + upload via
            // its own optimized path (typically GPU-side, no 200 MB
            // CGContext on the CPU). Mipmap generation is requested
            // up-front so we don't need a separate blit pass.
            let texture: MTLTexture?
            do {
                texture = try await loader.newTexture(
                    cgImage: cgImage,
                    options: [
                        .generateMipmaps: NSNumber(value: true),
                        .SRGB:            NSNumber(value: true),
                        .textureStorageMode: NSNumber(value: MTLStorageMode.shared.rawValue),
                        .textureUsage:    NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
                    ]
                )
            } catch {
                Log.canvas.error("MTKTextureLoader failed (\(String(describing: error), privacy: .public)); falling back to manual CGContext upload")
                texture = Self.manualUpload(cgImage: cgImage, device: loader.device, commandQueue: queue)
            }

            await MainActor.run { [weak self] in
                guard let self else { return }
                guard self.loadGeneration == gen else {
                    // A newer setImage was issued — drop this stale load.
                    return
                }
                guard let texture else {
                    Log.canvas.error("setImage: texture creation returned nil for \(Int(pixelSize.width))x\(Int(pixelSize.height))")
                    self.baseTexture = nil
                    self.imagePixelSize = .zero
                    return
                }
                self.baseTexture = texture
                self.imagePixelSize = pixelSize
                PerfTracker.mark("CanvasRenderer.setImage done (async)")
                self.onTextureReady?(pixelSize)
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

        return [
            SIMD4(left,  bottom, 0, 1),
            SIMD4(right, bottom, 1, 1),
            SIMD4(left,  top,    0, 0),
            SIMD4(right, bottom, 1, 1),
            SIMD4(right, top,    1, 0),
            SIMD4(left,  top,    0, 0)
        ]
    }
}
