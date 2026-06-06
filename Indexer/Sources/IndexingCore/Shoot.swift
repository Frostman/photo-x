import Foundation

/// A folder of `PhotoEntry`s being culled together. An entry can be
/// an `ARW + HIF` pair, an `ARW + JPG` pair, or a standalone preview
/// (HIF / JPG) with no RAW.
public struct Shoot: Identifiable, Hashable, Sendable {
    public let folderURL: URL
    public let entries: [PhotoEntry]

    public init(folderURL: URL, entries: [PhotoEntry]) {
        self.folderURL = folderURL
        self.entries = entries
    }

    public var id: URL { folderURL }
    public var isEmpty: Bool { entries.isEmpty }
    public var count: Int { entries.count }

    public func index(of entry: PhotoEntry) -> Int? {
        entries.firstIndex { $0.id == entry.id }
    }
}
