import CoreGraphics
import Foundation

struct DecodedImage {
    /// The image bytes as they sit in memory after the file decode —
    /// in SENSOR orientation, NOT pre-rotated to display orientation.
    /// The canvas renderer applies the EXIF orientation via texture-
    /// coordinate transform in the shader, which is essentially free
    /// on the GPU (vs. a 200 MB CPU rotation pass for portraits).
    let cgImage: CGImage

    /// EXIF orientation (1–8 per the TIFF spec) describing how the
    /// stored pixels need to be transformed to display correctly.
    /// 1 = no transform; 5/6/7/8 swap the width and height.
    let orientation: Int

    /// Display dimensions — width and height AFTER orientation is
    /// applied. AF overlay coordinates, viewport math, pixelZoom and
    /// 1:1 zoom all read this and would be off-by-rotation if they
    /// got the raw cgImage dimensions for a portrait shot.
    let pixelSize: CGSize

    let decodeMS: Double
    let colorSpaceName: String

    init(cgImage: CGImage,
         orientation: Int = 1,
         decodeMS: Double,
         colorSpaceName: String)
    {
        self.cgImage = cgImage
        self.orientation = orientation
        let isSwapped = orientation >= 5 && orientation <= 8
        self.pixelSize = isSwapped
            ? CGSize(width: cgImage.height, height: cgImage.width)
            : CGSize(width: cgImage.width, height: cgImage.height)
        self.decodeMS = decodeMS
        self.colorSpaceName = colorSpaceName
    }
}
