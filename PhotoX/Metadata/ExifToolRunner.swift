import Foundation

enum ExifToolRunner {
    private static let exifToolPath = "/opt/homebrew/bin/exiftool"

    enum ExifToolError: Error {
        case notInstalled
        case launchFailed(String)
        case nonZeroExit(Int32, String)
        case parseFailed
    }

    struct AFData: Sendable {
        var regions: [AFRegion] = []
        var settings: AFSettings = AFSettings()
    }

    /// Reads AF / focus / face metadata from a Sony ARW. Returns empty if
    /// exiftool isn't installed; the viewer still works without it.
    static func readAF(from url: URL) -> AFData {
        guard FileManager.default.isExecutableFile(atPath: exifToolPath) else {
            Log.app.notice("exiftool not at \(exifToolPath, privacy: .public) — skipping AF parse")
            return AFData()
        }
        do {
            let json = try runJSON(arguments: [
                "-j", "-G1",
                "-Sony:FocusLocation", "-Sony:FocusFrameSize",
                "-Sony:FocalPlaneAFPointArea", "-Sony:FocalPlaneAFPointLocation1",
                "-Sony:FocalPlaneAFPointLocation2", "-Sony:FocalPlaneAFPointLocation3",
                "-Sony:FocalPlaneAFPointLocation4", "-Sony:FocalPlaneAFPointLocation5",
                "-Sony:FocalPlaneAFPointLocation6", "-Sony:FocalPlaneAFPointLocation7",
                "-Sony:FocalPlaneAFPointLocation8", "-Sony:FocalPlaneAFPointLocation9",
                "-Sony:FocalPlaneAFPointsUsed",
                "-Sony:FocusMode", "-Sony:AFAreaModeSetting", "-Sony:AFAreaMode",
                "-Sony:AFTracking",
                "-Sony:Face1Position", "-Sony:Face2Position", "-Sony:Face3Position",
                "-Sony:Face4Position", "-Sony:Face5Position", "-Sony:Face6Position",
                "-Sony:FacesDetected",
                "-Composite:FocusDistance", "-Composite:FocusDistance2",
                url.path
            ])

            var data = AFData()
            data.settings = parseSettings(from: json)
            data.regions = parseRegions(from: json)
            return data
        } catch {
            Log.app.error("ExifToolRunner: \(String(describing: error), privacy: .public)")
            return AFData()
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

        do { try process.run() } catch {
            throw ExifToolError.launchFailed(error.localizedDescription)
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            throw ExifToolError.nonZeroExit(process.terminationStatus,
                                            String(data: errData, encoding: .utf8) ?? "")
        }

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = arr.first else {
            throw ExifToolError.parseFailed
        }
        return first
    }

    // MARK: - Settings

    private static func parseSettings(from dict: [String: Any]) -> AFSettings {
        var s = AFSettings()
        s.focusMode = string(dict, "Sony:FocusMode")
        s.afAreaMode = [string(dict, "Sony:AFAreaModeSetting"),
                        string(dict, "Sony:AFAreaMode")]
            .compactMap { $0 }
            .joined(separator: " / ")
            .nilIfEmpty
        s.afTracking = string(dict, "Sony:AFTracking")
        s.focusDistance = (string(dict, "Composite:FocusDistance")
            ?? string(dict, "Composite:FocusDistance2"))
            .map(prettyDistance)
        if let n = int(dict, "Sony:FocalPlaneAFPointsUsed") {
            s.pointsUsed = n
        }
        if let raw = string(dict, "Sony:FocusFrameSize") {
            s.focusFrameSize = raw.replacingOccurrences(of: "x", with: " × ")
        }
        return s
    }

    private static func prettyDistance(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased() == "inf" || trimmed.lowercased() == "infinity" {
            return "∞"
        }
        return trimmed
    }

    // MARK: - Regions

    private static func parseRegions(from dict: [String: Any]) -> [AFRegion] {
        var regions: [AFRegion] = []
        regions.append(contentsOf: parsePrimaryFocus(dict))
        regions.append(contentsOf: parseFocalPlanePoints(dict))
        regions.append(contentsOf: parseFaces(dict))
        return regions
    }

    private static func parsePrimaryFocus(_ dict: [String: Any]) -> [AFRegion] {
        guard let str = string(dict, "Sony:FocusLocation") else { return [] }
        let parts = str.split(separator: " ").compactMap { Int($0) }
        guard parts.count == 4 else { return [] }
        let imgW = parts[0], imgH = parts[1], fx = parts[2], fy = parts[3]

        let frameSize = string(dict, "Sony:FocusFrameSize") ?? "120x120"
        let dims = frameSize.split(whereSeparator: { $0 == "x" || $0 == " " }).compactMap { Int($0) }
        let fw = dims.first ?? 120
        let fh = dims.dropFirst().first ?? fw

        let rect = CGRect(
            x: CGFloat(fx) - CGFloat(fw) / 2,
            y: CGFloat(fy) - CGFloat(fh) / 2,
            width: CGFloat(fw),
            height: CGFloat(fh)
        )
        return [AFRegion(kind: .primaryFocus, rect: rect,
                         label: "\(imgW)×\(imgH) primary focus")]
    }

    /// Sony writes per-point AF coordinates in an INTERNAL 640×480 grid (not
    /// the reported FocalPlaneAFPointArea, which uses a smaller height that
    /// reflects sensor-area aspect). 640×480 is hardcoded — verified
    /// empirically against the A1 II sample (point y=240 → image y=2880 for
    /// 8640×5760 = exact center). May need adjustment for other bodies.
    private static let sonyAFGridSize = (w: CGFloat(640), h: CGFloat(480))

    private static func parseFocalPlanePoints(_ dict: [String: Any]) -> [AFRegion] {
        // The image-pixel dimensions live in FocusLocation as the first two ints.
        guard let locStr = string(dict, "Sony:FocusLocation") else { return [] }
        let locParts = locStr.split(separator: " ").compactMap { Int($0) }
        guard locParts.count >= 2 else { return [] }
        let imgW = CGFloat(locParts[0])
        let imgH = CGFloat(locParts[1])

        let xScale = imgW / sonyAFGridSize.w
        let yScale = imgH / sonyAFGridSize.h
        // Each point is ~20 grid-units. Use that as a visible dot size in image px.
        let dotSizeImagePx = max(20 * yScale, 80)

        var out: [AFRegion] = []
        for i in 1...9 {
            guard let s = string(dict, "Sony:FocalPlaneAFPointLocation\(i)") else { continue }
            let p = s.split(separator: " ").compactMap { Int($0) }
            guard p.count == 2 else { continue }
            let x = CGFloat(p[0]) * xScale
            let y = CGFloat(p[1]) * yScale
            out.append(AFRegion(
                kind: .focalPlanePoint,
                rect: CGRect(x: x - dotSizeImagePx / 2,
                             y: y - dotSizeImagePx / 2,
                             width: dotSizeImagePx,
                             height: dotSizeImagePx),
                label: "AF \(i)"
            ))
        }
        return out
    }

    /// Best-effort face parsing. ExifTool's Sony face fields vary by firmware;
    /// the common "FaceNPosition" string format is "y x width height" in some
    /// scaled coordinate system. Untested on the current sample (no face data).
    /// If face data is malformed, we just skip rather than throw.
    private static func parseFaces(_ dict: [String: Any]) -> [AFRegion] {
        guard let locStr = string(dict, "Sony:FocusLocation") else { return [] }
        let locParts = locStr.split(separator: " ").compactMap { Int($0) }
        guard locParts.count >= 2 else { return [] }
        let imgW = CGFloat(locParts[0])
        let imgH = CGFloat(locParts[1])

        var out: [AFRegion] = []
        for i in 1...6 {
            guard let s = string(dict, "Sony:Face\(i)Position") else { continue }
            let p = s.split(separator: " ").compactMap { Int($0) }
            guard p.count == 4 else { continue }
            // Sony's "FaceNPosition" is documented as: y x height width (yes, in
            // that order) in a 640-wide coord space. Scale linearly.
            let xScale = imgW / sonyAFGridSize.w
            let yScale = imgH / sonyAFGridSize.h
            let rect = CGRect(
                x: CGFloat(p[1]) * xScale,
                y: CGFloat(p[0]) * yScale,
                width: CGFloat(p[3]) * xScale,
                height: CGFloat(p[2]) * yScale
            )
            out.append(AFRegion(kind: .face, rect: rect, label: "Face \(i)"))
        }
        return out
    }

    // MARK: - Dict helpers

    private static func string(_ dict: [String: Any], _ key: String) -> String? {
        guard let v = dict[key] else { return nil }
        if let s = v as? String { return s.isEmpty ? nil : s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    private static func int(_ dict: [String: Any], _ key: String) -> Int? {
        if let i = dict[key] as? Int { return i }
        if let n = dict[key] as? NSNumber { return n.intValue }
        if let s = dict[key] as? String, let i = Int(s) { return i }
        return nil
    }
}

private extension Optional where Wrapped == String {
    var nilIfEmpty: String? {
        guard let self, !self.isEmpty else { return nil }
        return self
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
