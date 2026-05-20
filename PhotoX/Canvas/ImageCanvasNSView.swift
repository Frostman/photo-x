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
    /// Fires when a setImage() upload has bound the new texture (i.e.
    /// the user actually sees the new image). The payload is:
    /// - `token`: the caller's identifier (PhotoX uses pair stem).
    /// - `pixelSize`: display-orientation dimensions of the bound
    ///   texture. The AF overlay needs this lagged value so rects
    ///   stay correctly scaled when transitioning between portrait
    ///   and landscape pairs.
    var onImageDisplayed: ((String, CGSize) -> Void)?
    private var pendingToken: String = ""
    private var pendingOrientation: Int = 1
    /// DecodeKey for `pendingImage` — replayed into the renderer once
    /// it's built in `viewDidMoveToWindow`. Sentinel default for the
    /// before-first-setImage window; never read in that case because
    /// `pendingImage` is also nil.
    private var pendingKey: DecodeKey = DecodeKey(entryID: "",
                                                   variant: .preview,
                                                   decoder: .imageIO)

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
            if let renderer {
                metalLayer.device = renderer.device
                // Async texture loads call this back on the main actor
                // when baseTexture has been swapped in. We update our
                // imagePixelSize from the callback (not from setImage)
                // so geometry stays in lock-step with what's actually
                // bound — the OLD image keeps rendering at its OLD
                // size during the load window, no glitch frame. Token
                // is forwarded to onImageDisplayed so the model can
                // sync its displayed-pair state with the texture that
                // just landed.
                renderer.onTextureReady = { [weak self] token, pixelSize in
                    guard let self else { return }
                    self.imagePixelSize = pixelSize
                    // Fire commitDisplayed FIRST so SwiftUI invalidates
                    // AFPointOverlay with the new pair's regions, then
                    // defer the Metal commit to the next runloop tick.
                    // SwiftUI processes the @Observable change and
                    // commits AFPointOverlay's layer in the same
                    // CATransaction as the Metal present that follows
                    // — both land in the same vsync, so the user never
                    // sees the "new image + old AF" intermediate frame.
                    self.onImageDisplayed?(token, pixelSize)
                    DispatchQueue.main.async { [weak self] in
                        self?.scheduleDraw()
                    }
                }
            }
            if let pendingImage {
                renderer?.setImage(pendingImage,
                                   token: pendingToken,
                                   orientation: pendingOrientation,
                                   key: pendingKey)
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

    func setImage(_ cgImage: CGImage, token: String, orientation: Int, key: DecodeKey) {
        PerfTracker.mark("ImageCanvasNSView.setImage entered")
        if let renderer {
            // Renderer hits the texture cache synchronously on a HIT
            // (back-and-forth nav is instant) or coalesces async on a
            // MISS. The OLD baseTexture (+ OLD imagePixelSize) stay
            // bound during a MISS upload, so the previous frame stays
            // on screen instead of flashing. Token + orientation + key
            // ride along so onImageDisplayed can fire and the shader
            // can rotate UVs based on orientation.
            renderer.setImage(cgImage, token: token, orientation: orientation, key: key)
        } else {
            // Renderer hasn't been built yet (viewDidMoveToWindow runs
            // shortly after init). Stash everything; the first
            // setImage replay during viewDidMoveToWindow uses these
            // pending values. Pre-set imagePixelSize so any layout
            // that runs before the first async load completes has the
            // right geometry — swap dimensions for portrait
            // orientations.
            pendingImage = cgImage
            pendingToken = token
            pendingOrientation = orientation
            pendingKey = key
            let isSwapped = orientation >= 5 && orientation <= 8
            imagePixelSize = isSwapped
                ? CGSize(width: cgImage.height, height: cgImage.width)
                : CGSize(width: cgImage.width, height: cgImage.height)
        }
    }

    /// Called by SwiftUI when the external viewport changes. No-op if it matches our internal.
    func setViewportFromExternal(_ newViewport: CanvasViewport) {
        let clamped = clampToImageBounds(newViewport)
        guard viewport != clamped else { return }
        viewport = clamped
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
        viewport = clampToImageBounds(newViewport)
        renderer?.setViewport(viewport)
        scheduleDraw()
    }

    /// Wrap CanvasViewport.clampedOffset with the NSView's current image and
    /// drawable sizes so callers don't have to fish them out.
    private func clampToImageBounds(_ vp: CanvasViewport) -> CanvasViewport {
        guard imagePixelSize.width > 0, metalLayer.drawableSize.width > 0 else { return vp }
        return vp.clampedOffset(imagePixelSize: imagePixelSize,
                                viewPixelSize: metalLayer.drawableSize)
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
            // From fit → zoom to 1:1 centred on the click point so the
            // user lands on the pixel they targeted. From 1:1+ → back
            // to fit (no focal needed — fit centres the image).
            toggleFitOneToOne(focal: devicePoint(forEvent: event))
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

    /// Toggle between fit and 1:1. When zooming in from fit and a
    /// `focal` is supplied, the resulting 1:1 viewport is centred on
    /// that focal point (so the pixel the user double-clicked stays
    /// under the cursor). When `focal` is nil — or when zooming back
    /// out to fit — the image is centred.
    func toggleFitOneToOne(focal: CGPoint? = nil) {
        let pz = viewport.pixelZoom(imagePixelSize: imagePixelSize, viewPixelSize: metalLayer.drawableSize)
        let target: CanvasViewport
        if pz < 0.99 {
            if let focal {
                // From fit, the factor that reaches 1:1 is 1/fit.
                // Zoom from .identity around the click point so the
                // pixel under the cursor stays put. clampedOffset (in
                // applyViewportFromGesture) keeps the edge from
                // showing empty space if the focal point is near the
                // image boundary.
                let fit = CanvasViewport.fitScale(imagePixelSize: imagePixelSize,
                                                   viewPixelSize: metalLayer.drawableSize)
                let factor = fit > 0 ? 1.0 / fit : 1.0
                target = CanvasViewport.identity.zoomed(by: factor,
                                                         around: focal,
                                                         viewSize: metalLayer.drawableSize)
            } else {
                target = CanvasViewport.oneToOne(imagePixelSize: imagePixelSize,
                                                  viewPixelSize: metalLayer.drawableSize)
            }
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
