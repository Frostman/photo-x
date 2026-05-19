import Foundation

struct DecodeKey: Hashable, Sendable {
    let pairID: String
    let variant: ImageVariant
    let decoder: DecoderChoice
}

@MainActor
final class DecodedImageCache {
    private var entries: [DecodeKey: DecodedImage] = [:]
    private var insertionOrder: [DecodeKey] = []
    let capacity: Int

    init(capacity: Int = 20) {
        self.capacity = capacity
    }

    func get(_ key: DecodeKey) -> DecodedImage? {
        entries[key]
    }

    func set(_ image: DecodedImage, for key: DecodeKey) {
        if entries[key] != nil {
            insertionOrder.removeAll { $0 == key }
        }
        entries[key] = image
        insertionOrder.append(key)
        while insertionOrder.count > capacity {
            let evict = insertionOrder.removeFirst()
            entries.removeValue(forKey: evict)
        }
    }

    func clear() {
        entries.removeAll()
        insertionOrder.removeAll()
    }
}
