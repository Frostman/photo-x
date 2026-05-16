import CoreGraphics
import Foundation

struct DecodedImage {
    let cgImage: CGImage
    let pixelSize: CGSize
    let decodeMS: Double
    let colorSpaceName: String

    init(cgImage: CGImage, decodeMS: Double, colorSpaceName: String) {
        self.cgImage = cgImage
        self.pixelSize = CGSize(width: cgImage.width, height: cgImage.height)
        self.decodeMS = decodeMS
        self.colorSpaceName = colorSpaceName
    }
}
