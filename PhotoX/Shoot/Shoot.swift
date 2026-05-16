import Foundation

/// A folder of paired RAW + HEIF files being culled together.
struct Shoot: Identifiable, Hashable, Sendable {
    let folderURL: URL
    let pairs: [PhotoPair]

    var id: URL { folderURL }
    var isEmpty: Bool { pairs.isEmpty }
    var count: Int { pairs.count }

    func index(of pair: PhotoPair) -> Int? {
        pairs.firstIndex { $0.id == pair.id }
    }
}
