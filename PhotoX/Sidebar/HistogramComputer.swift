import CoreGraphics
import Foundation

struct Histogram: Hashable, Sendable {
    var red: [Int]
    var green: [Int]
    var blue: [Int]
    var totalPixels: Int

    static let empty = Histogram(
        red: Array(repeating: 0, count: 256),
        green: Array(repeating: 0, count: 256),
        blue: Array(repeating: 0, count: 256),
        totalPixels: 0
    )
}

enum HistogramComputer {
    /// Computes an sRGB-encoded 256-bucket per-channel histogram from a
    /// downscaled copy of the image. Downscale keeps the cost ~10–20 ms on
    /// M1 Max regardless of source resolution.
    static func compute(from cgImage: CGImage, sampleWidth: Int = 1024) -> Histogram {
        let srcW = cgImage.width
        let srcH = cgImage.height
        guard srcW > 0, srcH > 0 else { return .empty }

        let targetW = min(sampleWidth, srcW)
        let targetH = max(1, Int((Double(targetW) * Double(srcH) / Double(srcW)).rounded()))
        let bytesPerRow = targetW * 4
        let byteCount = bytesPerRow * targetH

        guard let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return .empty }
        let bitmapInfo: UInt32 = CGImageAlphaInfo.premultipliedLast.rawValue
                               | CGBitmapInfo.byteOrderDefault.rawValue

        guard let context = CGContext(
            data: nil,
            width: targetW,
            height: targetH,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: cs,
            bitmapInfo: bitmapInfo
        ), let dataPtr = context.data?.assumingMemoryBound(to: UInt8.self) else {
            return .empty
        }

        context.interpolationQuality = .low
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))

        var red = Array(repeating: 0, count: 256)
        var green = Array(repeating: 0, count: 256)
        var blue = Array(repeating: 0, count: 256)

        let pixelCount = targetW * targetH
        for i in 0..<pixelCount {
            let base = i * 4
            red[Int(dataPtr[base])] += 1
            green[Int(dataPtr[base + 1])] += 1
            blue[Int(dataPtr[base + 2])] += 1
        }
        _ = byteCount

        return Histogram(red: red, green: green, blue: blue, totalPixels: pixelCount)
    }
}
