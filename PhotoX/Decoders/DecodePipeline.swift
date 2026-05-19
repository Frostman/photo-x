import Foundation

@MainActor
final class DecodePipeline {
    /// Decoded-pixel cache: ~200 MB per 50-MP frame × ~20 entries =
    /// ~4 GB worst case, but typical working sets are much smaller.
    /// Hot path for the currently-displayed frame + its neighbours.
    let cache: DecodedImageCache

    /// Raw-byte cache for HIFs: 2 GB ≈ ~200+ HIFs in RAM. Persists
    /// across shoot switches; LRU naturally trims. Sits in front of the
    /// HEIF decoder so back-and-forth culling never re-reads from the
    /// source card.
    let hifBytes: HIFBytesCache

    private let heifDecoder: any ImageDecoder
    private let rawImageIODecoder: any ImageDecoder = RAWImageIODecoder()
    private let rawLibRawDecoder: any ImageDecoder = RAWLibRawDecoder()

    private var inflight: [DecodeKey: Task<DecodedImage, Error>] = [:]

    init(cacheCapacity: Int = 20,
         hifBytesCapacity: Int = 2 * 1024 * 1024 * 1024) {
        self.cache = DecodedImageCache(capacity: cacheCapacity)
        self.hifBytes = HIFBytesCache(byteCapacity: hifBytesCapacity)
        self.heifDecoder = HEIFDecoder(bytesCache: self.hifBytes)
    }

    /// Cheap pre-check — does the pipeline already have this image cached?
    /// Used by callers that want to record whether a decode was instant
    /// (cache hit) or paid wall time (fresh decode).
    func isCached(pair: PhotoPair, variant: ImageVariant, decoder: DecoderChoice) -> Bool {
        let keyDecoder: DecoderChoice = (variant == .heif) ? .imageIO : decoder
        let key = DecodeKey(pairID: pair.id, variant: variant, decoder: keyDecoder)
        return cache.get(key) != nil
    }

    func decode(pair: PhotoPair, variant: ImageVariant, decoder: DecoderChoice) async throws -> DecodedImage {
        // Decoder is a RAW-only concern: HEIF always goes through HEIFDecoder.
        // Normalize the cache key so we don't double-cache the same HEIF under
        // different decoder slots.
        let keyDecoder: DecoderChoice = (variant == .heif) ? .imageIO : decoder
        let key = DecodeKey(pairID: pair.id, variant: variant, decoder: keyDecoder)

        if let cached = cache.get(key) {
            #if DEBUG
            Log.decode.notice("cache hit: \(key.pairID, privacy: .public) \(key.variant.rawValue, privacy: .public)/\(key.decoder.rawValue, privacy: .public)")
            #endif
            return cached
        }

        if let existing = inflight[key] {
            return try await existing.value
        }

        let decoderImpl = decoderFor(variant: variant, choice: decoder)
        let url = (variant == .heif) ? pair.heifURL : pair.rawURL

        #if DEBUG
        Log.decode.notice("start: \(key.pairID, privacy: .public) \(key.variant.rawValue, privacy: .public)/\(key.decoder.rawValue, privacy: .public) → \(url.lastPathComponent, privacy: .public)")
        #endif
        let task = Task<DecodedImage, Error> {
            try await decoderImpl.decode(url: url)
        }
        inflight[key] = task
        defer { inflight[key] = nil }

        let result = try await task.value
        cache.set(result, for: key)
        #if DEBUG
        Log.decode.notice("done: \(key.pairID, privacy: .public) \(key.variant.rawValue, privacy: .public)/\(key.decoder.rawValue, privacy: .public) in \(result.decodeMS, format: .fixed(precision: 1)) ms")
        #endif
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
