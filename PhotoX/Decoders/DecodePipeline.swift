import Foundation

/// Orchestrates HEIF + RAW decoding. No longer caches `DecodedImage`
/// results — that role moved downstream to `MTLTextureCache`, which
/// stores the GPU artifact (the form actually used for display).
/// Single-flight dedup is kept so concurrent decodes of the same key
/// share one underlying decode Task; this prevents redundant CPU work
/// when both the user-facing nav and a prefetch ask for the same pair
/// at the same instant.
///
/// HEIF bytes are still cached via `HIFBytesCache` (sits in front of
/// the HEIF decoder); the byte cache is now cleared on shoot switch so
/// stale shoots' data doesn't outlive the session.
@MainActor
final class DecodePipeline {
    /// Raw-byte cache for HIFs: 2 GB ≈ ~200+ HIFs in RAM. Sits in
    /// front of the HEIF decoder so back-and-forth culling never
    /// re-reads from the source card. Cleared on shoot switch by
    /// ViewerState.resetForShootSwitch.
    let hifBytes: HIFBytesCache

    private let heifDecoder: any ImageDecoder
    private let rawImageIODecoder: any ImageDecoder = RAWImageIODecoder()
    private let rawLibRawDecoder: any ImageDecoder = RAWLibRawDecoder()

    private var inflight: [DecodeKey: Task<DecodedImage, Error>] = [:]

    init(hifBytesCapacity: Int = 2 * 1024 * 1024 * 1024) {
        self.hifBytes = HIFBytesCache(byteCapacity: hifBytesCapacity)
        self.heifDecoder = HEIFDecoder(bytesCache: self.hifBytes)
    }

    /// Decode `pair.variant` into a `DecodedImage`. Single-flight per
    /// `DecodeKey`: concurrent callers share one decode. The result is
    /// NOT cached on this side — caller is expected to consume the
    /// CGImage inline (upload to `MTLTextureCache.warm`, compute the
    /// histogram, etc.) and let the value drop.
    func decode(pair: PhotoPair, variant: ImageVariant, decoder: DecoderChoice) async throws -> DecodedImage {
        // Decoder is a RAW-only concern: HEIF always goes through HEIFDecoder.
        // Normalize the dedup key so HEIF nav doesn't accidentally fan out
        // across different decoder slots.
        let keyDecoder: DecoderChoice = (variant == .heif) ? .imageIO : decoder
        let key = DecodeKey(pairID: pair.id, variant: variant, decoder: keyDecoder)

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
