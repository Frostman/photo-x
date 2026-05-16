import Foundation

enum SamplePathProvider {
    /// Directory to scan on launch. Override via `PHOTOX_SAMPLE_DIR` env var
    /// (settable in the Xcode scheme); falls back to the repo's `sample/` folder
    /// so the dev loop works out of the box.
    static let defaultDirectory = URL(fileURLWithPath: "/Users/frostman/workspace/personal/photo-x/sample")

    static func sampleDirectory() -> URL {
        if let env = ProcessInfo.processInfo.environment["PHOTOX_SAMPLE_DIR"], !env.isEmpty {
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath)
        }
        return defaultDirectory
    }

    static func firstPair() -> PhotoPair? {
        let dir = sampleDirectory()
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            return nil
        }
        return PairFinder.firstPair(in: contents)
    }
}
