import Observation
import SwiftUI

@MainActor
@Observable
final class ViewerState {
    var pair: PhotoPair?
    var decoder: DecoderChoice = .imageIO

    var displayedVariant: ImageVariant = .heif
    var requestedVariant: ImageVariant = .heif
    var autoSwapEnabled: Bool = true

    var overlays: OverlayToggles = .init()
    var sidebarVisible: Bool = true

    var viewport: CanvasViewport = .identity
    var currentImage: DecodedImage?
    var isDecoding: Bool = false
    var errorMessage: String?

    var lastDecodeMS: [DecoderChoice: Double] = [:]

    /// Replaces the current pair and decodes its HEIF preview. Commit 5 will
    /// route this through DecodePipeline and handle the HEIF↔RAW swap; today
    /// it always decodes the HEIF.
    func loadPair(_ pair: PhotoPair, using decoder: any ImageDecoder = HEIFDecoder()) async {
        self.pair = pair
        self.currentImage = nil
        self.errorMessage = nil
        self.isDecoding = true
        defer { isDecoding = false }

        Log.app.notice("loadPair: \(pair.stem, privacy: .public) — heif=\(pair.heifURL.path, privacy: .public)")
        do {
            let decoded = try await decoder.decode(url: pair.heifURL)
            self.currentImage = decoded
            self.displayedVariant = .heif
            self.lastDecodeMS[.imageIO] = decoded.decodeMS
            Log.app.notice("loadPair: decoded \(decoded.cgImage.width)x\(decoded.cgImage.height) in \(decoded.decodeMS, format: .fixed(precision: 1)) ms")
        } catch {
            Log.app.error("loadPair: \(String(describing: error), privacy: .public)")
            self.errorMessage = String(describing: error)
        }
    }
}
