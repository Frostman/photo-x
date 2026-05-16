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
        // MTKTextureLoader trips on 10-bit HEIF (rdar://143602439 — Sony A1 II HIF
        // is 10-bpc / RGB10A2 packed), so we redraw into an 8-bpc BGRA buffer and
        // upload manually. Costs ~50-200 ms per 50MP image on the main thread; an
        // acceptable tradeoff for commit 3, will revisit when the 16-bit / Display
        // P3 pipeline lands.
        guard let texture = makeTexture(from: cgImage) else {
            Log.canvas.error("setImage: makeTexture returned nil for \(cgImage.width)x\(cgImage.height)")
            baseTexture = nil
            imagePixelSize = .zero
            return
        }
        baseTexture = texture
        imagePixelSize = CGSize(width: cgImage.width, height: cgImage.height)
        Log.canvas.notice("setImage: \(cgImage.width)x\(cgImage.height) bpc=\(cgImage.bitsPerComponent) bpp=\(cgImage.bitsPerPixel) → texture uploaded")
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

        context.interpolationQuality = .high
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
            Log.canvas.error("makeTexture: MTLTexture creation failed")
            return nil
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

    func setViewport(_ viewport: CanvasViewport) {
        self.viewport = viewport
    }

    func draw(in layer: CAMetalLayer) {
        guard let baseTexture else {
            drawClear(in: layer)
            return
        }

        let drawableSize = layer.drawableSize
        guard drawableSize.width > 0, drawableSize.height > 0,
              let drawable = layer.nextDrawable() else { return }

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
        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentTexture(baseTexture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
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
