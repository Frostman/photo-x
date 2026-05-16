import AppKit
import CoreGraphics
import Metal
import QuartzCore

@MainActor
final class ImageCanvasNSView: NSView {
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    private var renderer: CanvasRenderer?
    private var pendingImage: CGImage?

    private var viewport: CanvasViewport = .identity
    private var imagePixelSize: CGSize = .zero

    var onViewportChange: ((CanvasViewport, CGFloat) -> Void)?

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

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func makeBackingLayer() -> CALayer {
        let metal = CAMetalLayer()
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
            if let renderer { metalLayer.device = renderer.device }
            if let pendingImage {
                renderer?.setImage(pendingImage)
                imagePixelSize = CGSize(width: pendingImage.width, height: pendingImage.height)
                self.pendingImage = nil
            }
            renderer?.setViewport(viewport)
            renderer?.setShowClipping(showClipping)
            renderer?.setShowPeaking(showPeaking)
        }
        updateDrawableSize()
        scheduleDraw()
        // Intentionally do NOT call window?.makeFirstResponder(self) —
        // mouse/scroll events work without first-responder status, and stealing
        // it from SwiftUI's focusable container kills .onKeyPress for arrow
        // keys after every NSView rebuild.
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
        PerfTracker.mark("ImageCanvasNSView.setImage entered")
        if let renderer {
            renderer.setImage(cgImage)
            imagePixelSize = CGSize(width: cgImage.width, height: cgImage.height)
            scheduleDraw()
        } else {
            pendingImage = cgImage
            imagePixelSize = CGSize(width: cgImage.width, height: cgImage.height)
        }
    }

    /// Called by SwiftUI when the external viewport changes. No-op if it matches our internal.
    func setViewportFromExternal(_ newViewport: CanvasViewport) {
        guard viewport != newViewport else { return }
        viewport = newViewport
        renderer?.setViewport(viewport)
        scheduleDraw()
    }

    private var showClipping: Bool = false
    func setShowClipping(_ on: Bool) {
        guard on != showClipping else { return }
        showClipping = on
        renderer?.setShowClipping(on)
        scheduleDraw()
    }

    private var showPeaking: Bool = false
    func setShowPeaking(_ on: Bool) {
        guard on != showPeaking else { return }
        showPeaking = on
        renderer?.setShowPeaking(on)
        scheduleDraw()
    }

    private func applyViewportFromGesture(_ newViewport: CanvasViewport) {
        viewport = newViewport
        renderer?.setViewport(viewport)
        scheduleDraw()
    }

    private var lastEmittedPixelZoom: CGFloat = -1
    private var lastEmittedViewport: CanvasViewport?

    private func scheduleDraw() {
        guard let renderer, window != nil else { return }
        renderer.draw(in: metalLayer)
        emitViewportIfChanged()
    }

    /// Emit (viewport, pixelZoom) up to SwiftUI whenever any input changed: gesture,
    /// external set, image load, or window resize (which changes drawableSize → pz).
    private func emitViewportIfChanged() {
        guard imagePixelSize.width > 0, metalLayer.drawableSize.width > 0 else { return }
        let pz = viewport.pixelZoom(imagePixelSize: imagePixelSize, viewPixelSize: metalLayer.drawableSize)
        if lastEmittedViewport != viewport || abs(pz - lastEmittedPixelZoom) > 0.001 {
            lastEmittedViewport = viewport
            lastEmittedPixelZoom = pz
            onViewportChange?(viewport, pz)
        }
    }

    // MARK: - Gestures

    /// Convert NSEvent location-in-window to device-pixel coordinates in our view space.
    private func devicePoint(forEvent event: NSEvent) -> CGPoint {
        let local = convert(event.locationInWindow, from: nil)
        let scale = window?.backingScaleFactor ?? 1.0
        return CGPoint(x: local.x * scale, y: local.y * scale)
    }

    override func magnify(with event: NSEvent) {
        let factor = 1.0 + event.magnification
        let focal = devicePoint(forEvent: event)
        applyViewportFromGesture(viewport.zoomed(by: factor, around: focal, viewSize: metalLayer.drawableSize))
    }

    override func scrollWheel(with event: NSEvent) {
        let scale = window?.backingScaleFactor ?? 1.0
        if event.modifierFlags.contains(.command) {
            // ⌘ + scroll → zoom
            let factor = 1.0 + (event.scrollingDeltaY * 0.01)
            let focal = devicePoint(forEvent: event)
            applyViewportFromGesture(viewport.zoomed(by: factor, around: focal, viewSize: metalLayer.drawableSize))
        } else {
            // Two-finger pan: scrollingDelta is in points, positive = content moves right/down
            let dx = event.scrollingDeltaX * scale
            let dy = -event.scrollingDeltaY * scale  // CG y-down → our y-up
            applyViewportFromGesture(viewport.panned(by: CGPoint(x: dx, y: dy)))
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            toggleFitOneToOne()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let scale = window?.backingScaleFactor ?? 1.0
        let dx = event.deltaX * scale
        let dy = -event.deltaY * scale  // event.deltaY uses y-down
        applyViewportFromGesture(viewport.panned(by: CGPoint(x: dx, y: dy)))
    }

    override func keyDown(with event: NSEvent) {
        // Forward unhandled keys to next responder so SwiftUI .onKeyPress still fires.
        nextResponder?.keyDown(with: event)
    }

    func toggleFitOneToOne() {
        let pz = viewport.pixelZoom(imagePixelSize: imagePixelSize, viewPixelSize: metalLayer.drawableSize)
        let target: CanvasViewport
        if pz < 0.99 {
            target = CanvasViewport.oneToOne(imagePixelSize: imagePixelSize, viewPixelSize: metalLayer.drawableSize)
        } else {
            target = .identity
        }
        applyViewportFromGesture(target)
    }

    func setViewportToFit() {
        applyViewportFromGesture(.identity)
    }

    func setViewportToOneToOne() {
        let target = CanvasViewport.oneToOne(imagePixelSize: imagePixelSize, viewPixelSize: metalLayer.drawableSize)
        applyViewportFromGesture(target)
    }
}
