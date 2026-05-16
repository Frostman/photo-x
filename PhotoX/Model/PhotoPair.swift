import Foundation

struct PhotoPair: Identifiable, Hashable, Sendable {
    let rawURL: URL
    let heifURL: URL
    let stem: String

    var id: String { stem }
}

extension PhotoPair {
    static func pair(rawURL: URL, heifURL: URL) -> PhotoPair {
        PhotoPair(
            rawURL: rawURL,
            heifURL: heifURL,
            stem: rawURL.deletingPathExtension().lastPathComponent
        )
    }
}
