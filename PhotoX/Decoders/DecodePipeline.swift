import Foundation

@MainActor
final class DecodePipeline {
    let cache: DecodedImageCache

    private let heifDecoder: any ImageDecoder = HEIFDecoder()
    private let rawImageIODecoder: any ImageDecoder = RAWImageIODecoder()
    private let rawLibRawDecoder: any ImageDecoder = RAWLibRawDecoder()

    private var inflight: [DecodeKey: Task<DecodedImage, Error>] = [:]

    init(cacheCapacity: Int = 4) {
        self.cache = DecodedImageCache(capacity: cacheCapacity)
    }

    func decode(pair: PhotoPair, variant: ImageVariant, decoder: DecoderChoice) async throws -> DecodedImage {
        let key = DecodeKey(pairID: pair.id, variant: variant, decoder: decoder)

        if let cached = cache.get(key) {
            Log.decode.notice("cache hit: \(key.pairID, privacy: .public) \(key.variant.rawValue, privacy: .public)/\(key.decoder.rawValue, privacy: .public)")
            return cached
        }

        if let existing = inflight[key] {
            return try await existing.value
        }

        let decoderImpl = decoderFor(variant: variant, choice: decoder)
        let url = (variant == .heif) ? pair.heifURL : pair.rawURL

        Log.decode.notice("start: \(key.pairID, privacy: .public) \(key.variant.rawValue, privacy: .public)/\(key.decoder.rawValue, privacy: .public) → \(url.lastPathComponent, privacy: .public)")
        let task = Task<DecodedImage, Error> {
            try await decoderImpl.decode(url: url)
        }
        inflight[key] = task
        defer { inflight[key] = nil }

        let result = try await task.value
        cache.set(result, for: key)
        Log.decode.notice("done: \(key.pairID, privacy: .public) \(key.variant.rawValue, privacy: .public)/\(key.decoder.rawValue, privacy: .public) in \(result.decodeMS, format: .fixed(precision: 1)) ms")
        return result
    }

    private func decoderFor(variant: ImageVariant, choice: DecoderChoice) -> any ImageDecoder {
        switch variant {
        case .heif:
            return heifDecoder
        case .raw:
            switch choice {
            case .imageIO: return rawImageIODecoder
            case .libRaw:  return rawLibRawDecoder
            }
        }
    }
}
