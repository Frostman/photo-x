import Foundation

/// Resolves the repo's `sample/` directory for the unit suite.
///
/// Mirrors `PhotoXUITestCase.repoSampleURL`: when
/// `PHOTOX_FIXTURE_SOURCE_DIR` is injected by the vm-test
/// xctestrun, points at the VM's local fixture copy; otherwise
/// walks up from `#file` (which the test bundle was compiled
/// against — always inside the repo) until it finds a `sample/`
/// sibling. Lets integration tests that previously hard-coded
/// `/Users/frostman/.../sample` run unchanged in the VM where
/// the host repo path doesn't exist.
enum RepoSample {
    static let url: URL = {
        if let override = ProcessInfo.processInfo.environment["PHOTOX_FIXTURE_SOURCE_DIR"] {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: override, isDirectory: &isDir),
               isDir.boolValue {
                return URL(fileURLWithPath: override)
            }
        }
        var dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        while dir.path != "/" {
            let candidate = dir.appendingPathComponent("sample")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir),
               isDir.boolValue {
                return candidate
            }
            dir = dir.deletingLastPathComponent()
        }
        fatalError("RepoSample: couldn't find sample/ above \(#file)")
    }()
}
