import CoreGraphics
import Metal
import QuartzCore

@MainActor
final class CanvasRenderer {
    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState

    private var baseTexture: MTLTexture?
    private var imagePixelSize: CGSize = .zero
    private var viewport: CanvasViewport = .identity
    private var showClipping: Bool = false
    private var showPeaking: Bool = false
    private var peakingThreshold: Float = 0.15

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
    }

    func setImage(_ cgImage: CGImage) {
        PerfTracker.mark("CanvasRenderer.setImage entered")
        guard let texture = makeTexture(from: cgImage) else {
            Log.canvas.error("setImage: makeTexture returned nil for \(cgImage.width)x\(cgImage.height)")
            baseTexture = nil
            imagePixelSize = .zero
            return
        }
        baseTexture = texture
        imagePixelSize = CGSize(width: cgImage.width, height: cgImage.height)
        PerfTracker.mark("CanvasRenderer.setImage done")
    }

    private func makeTexture(from cgImage: CGImage) -> MTLTexture? {
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
            Log.canvas.error("makeTexture: CGContext creation failed")
            return nil
        }
        PerfTracker.mark("CGContext allocated (\(bytesPerRow * height / 1_000_000) MB)")

        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        PerfTracker.mark("CGContext.draw done")

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: width,
            height: height,
            mipmapped: true
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            Log.canvas.error("makeTexture: MTLTexture creation failed")
            return nil
        }
        PerfTracker.mark("MTLTexture allocated")

        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: dataPtr,
            bytesPerRow: bytesPerRow
        )
        PerfTracker.mark("MTLTexture.replace done")

        if let cmd = commandQueue.makeCommandBuffer(),
           let blit = cmd.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
            cmd.commit()
        }
        PerfTracker.mark("mipmap blit committed")

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
