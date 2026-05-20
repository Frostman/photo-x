import Foundation

/// A folder of `PhotoEntry`s being culled together. An entry can be
/// an `ARW + HIF` pair, an `ARW + JPG` pair, or a standalone preview
/// (HIF / JPG) with no RAW.
struct Shoot: Identifiable, Hashable, Sendable {
    let folderURL: URL
    let entries: [PhotoEntry]

    var id: URL { folderURL }
    var isEmpty: Bool { entries.isEmpty }
    var count: Int { entries.count }

    func index(of entry: PhotoEntry) -> Int? {
        entries.firstIndex { $0.id == entry.id }
    }
}
