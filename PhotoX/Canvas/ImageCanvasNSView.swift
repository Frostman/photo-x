import AppKit
import CoreGraphics
import Metal
import QuartzCore

@MainActor
final class ImageCanvasNSView: NSView {
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    private var renderer: CanvasRenderer?
    private var pendingImage: CGImage?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
    }

    override func makeBackingLayer() -> CALayer {
        let metal = CAMetalLayer()
        // Commit 3 uses sRGB throughout for visually-correct gamma on screen.
        // Display P3 / 16-bit float pipeline lands when we need RAW color comparison.
        metal.pixelFormat = .bgra8Unorm_srgb
        metal.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metal.framebufferOnly = true
        metal.isOpaque = true
        metal.needsDisplayOnBoundsChange = true
        metal.contentsGravity = .resize
        return metal
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        if renderer == nil {
            renderer = CanvasRenderer(layerPixelFormat: metalLayer.pixelFormat)
            if let renderer {
                metalLayer.device = renderer.device
            }
            if let pendingImage {
                renderer?.setImage(pendingImage)
                self.pendingImage = nil
            }
        }
        updateDrawableSize()
        scheduleDraw()
    }

    override func layout() {
        super.layout()
        updateDrawableSize()
        scheduleDraw()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let scale = window?.backingScaleFactor {
            metalLayer.contentsScale = scale
        }
        updateDrawableSize()
        scheduleDraw()
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? 2.0
        let size = bounds.size
        let drawable = CGSize(width: max(1, size.width * scale), height: max(1, size.height * scale))
        if metalLayer.drawableSize != drawable {
            metalLayer.drawableSize = drawable
        }
    }

    func setImage(_ cgImage: CGImage) {
        if let renderer {
            renderer.setImage(cgImage)
            scheduleDraw()
        } else {
            pendingImage = cgImage
        }
    }

    func setViewport(_ viewport: CanvasViewport) {
        renderer?.setViewport(viewport)
        scheduleDraw()
    }

    private func scheduleDraw() {
        guard let renderer, window != nil else { return }
        renderer.draw(in: metalLayer)
    }
}
