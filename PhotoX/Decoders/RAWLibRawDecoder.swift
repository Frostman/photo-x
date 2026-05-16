import CoreGraphics
import Foundation

struct RAWLibRawDecoder: ImageDecoder {
    func decode(url: URL) async throws -> DecodedImage {
        try await Task.detached(priority: .userInitiated) {
            try Self.decodeSync(url: url)
        }.value
    }

    private static func decodeSync(url: URL) throws -> DecodedImage {
        let start = CFAbsoluteTimeGetCurrent()

        let cgImage: CGImage
        do {
            // Swift bridges the Obj-C `error:` parameter into `throws`.
            cgImage = try LibRawWrapper.decodeImage(at: url)
        } catch let nsError as NSError {
            throw DecodeError.libRawFailure(code: Int32(nsError.code),
                                            message: nsError.localizedDescription)
        }

        let decodeMS = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
        let colorSpaceName = cgImage.colorSpace?.name as String? ?? "unknown"
        return DecodedImage(
            cgImage: cgImage,
            decodeMS: decodeMS,
            colorSpaceName: colorSpaceName
        )
    }
}
