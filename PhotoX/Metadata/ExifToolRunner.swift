import Foundation

enum ExifToolRunner {
    private static let exifToolPath = "/opt/homebrew/bin/exiftool"

    enum ExifToolError: Error {
        case notInstalled
        case launchFailed(String)
        case nonZeroExit(Int32, String)
        case parseFailed
    }

    /// Reads AF / focus / face metadata from a Sony ARW file. Returns an empty
    /// array if exiftool isn't installed or if the file has no AF data — the
    /// viewer still works without it.
    static func readAFRegions(from url: URL) -> [AFRegion] {
        guard FileManager.default.isExecutableFile(atPath: exifToolPath) else {
            Log.app.notice("exiftool not at \(exifToolPath, privacy: .public) — skipping AF parse")
            return []
        }
        do {
            let json = try runJSON(arguments: [
                "-j", "-G1", "-Sony:FocusLocation", "-Sony:FocusFrameSize",
                url.path
            ])
            return parseAFRegions(from: json)
        } catch {
            Log.app.error("ExifToolRunner: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    private static func runJSON(arguments: [String]) throws -> [String: Any] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exifToolPath)
        process.arguments = arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw ExifToolError.launchFailed(error.localizedDescription)
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let errStr = String(data: errData, encoding: .utf8) ?? ""
            throw ExifToolError.nonZeroExit(process.terminationStatus, errStr)
        }

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = arr.first else {
            throw ExifToolError.parseFailed
        }
        return first
    }

    private static func parseAFRegions(from dict: [String: Any]) -> [AFRegion] {
        var regions: [AFRegion] = []

        // Sony:FocusLocation = "ImgW ImgH FocusX FocusY" — primary focus point in
        // image-pixel coordinates relative to the FULL image (not the cropped HEIF).
        if let str = (dict["Sony:FocusLocation"] as? String) ?? (dict["1:Sony:FocusLocation"] as? String) {
            let parts = str.split(separator: " ").compactMap { Int($0) }
            if parts.count == 4 {
                let imgW = parts[0], imgH = parts[1]
                let fx = parts[2], fy = parts[3]

                let frameSize = (dict["Sony:FocusFrameSize"] as? String) ?? "120x120"
                let dims = frameSize.split(whereSeparator: { $0 == "x" || $0 == " " }).compactMap { Int($0) }
                let fw = dims.first ?? 120
                let fh = dims.dropFirst().first ?? fw

                let rect = CGRect(
                    x: CGFloat(fx) - CGFloat(fw) / 2,
                    y: CGFloat(fy) - CGFloat(fh) / 2,
                    width: CGFloat(fw),
                    height: CGFloat(fh)
                )
                regions.append(AFRegion(
                    kind: .primaryFocus,
                    rect: rect,
                    label: "\(imgW)×\(imgH) primary focus"
                ))
            }
        }

        return regions
    }
}
