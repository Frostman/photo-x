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

    init?(layerPixelFormat: MTLPixelFormat) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = try? device.makeDefaultLibrary(bundle: .main),
              let vertexFn = library.makeFunction(name: "vertex_main"),
              let fragmentFn = library.makeFunction(name: "fragment_main")
        else { return nil }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFn
        descriptor.fragmentFunction = fragmentFn
        descriptor.colorAttachments[0].pixelFormat = layerPixelFormat
        descriptor.colorAttachments[0].isBlendingEnabled = false

        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else {
            return nil
        }

        self.device = device
        self.commandQueue = queue
        self.pipelineState = pipeline
        self.textureLoader = MTKTextureLoader(device: device)
    }

    func setImage(_ cgImage: CGImage) {
        // SRGB: true → texture format is bgra8Unorm_sRGB → GPU decodes gamma on sample.
        // Pair this with a bgra8Unorm_sRGB layer so writes are re-encoded — produces a
        // visually-correct image on screen. Full Display P3 / 16-bit pipeline comes later.
        let options: [MTKTextureLoader.Option: Any] = [
            .SRGB: true,
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
            .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue),
            .generateMipmaps: true
        ]
        do {
            baseTexture = try textureLoader.newTexture(cgImage: cgImage, options: options)
            imagePixelSize = CGSize(width: cgImage.width, height: cgImage.height)
        } catch {
            baseTexture = nil
            imagePixelSize = .zero
        }
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
