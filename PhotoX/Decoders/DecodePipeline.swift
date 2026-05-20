import Foundation

/// Orchestrates preview + RAW decoding. No longer caches `DecodedImage`
/// results — that role moved downstream to `MTLTextureCache`, which
/// stores the GPU artifact (the form actually used for display).
/// Single-flight dedup is kept so concurrent decodes of the same key
/// share one underlying decode Task; this prevents redundant CPU work
/// when both the user-facing nav and a prefetch ask for the same entry
/// at the same instant.
///
/// Preview-file bytes (HIF / HEIF / HEIC / JPG / JPEG) are still cached
/// via `PreviewBytesCache` (sits in front of `PreviewDecoder`); the
/// byte cache is now cleared on shoot switch so stale shoots' data
/// doesn't outlive the session.
@MainActor
final class DecodePipeline {
    /// Raw-byte cache for preview files: 2 GB ≈ ~200+ HIFs in RAM.
    /// Sits in front of `PreviewDecoder` so back-and-forth culling
    /// never re-reads from the source card. Cleared on shoot switch
    /// by `ViewerState.resetForShootSwitch`.
    let previewBytes: PreviewBytesCache

    private let previewDecoder: any ImageDecoder
    private let rawImageIODecoder: any ImageDecoder = RAWImageIODecoder()
    private let rawLibRawDecoder: any ImageDecoder = RAWLibRawDecoder()

    private var inflight: [DecodeKey: Task<DecodedImage, Error>] = [:]

    init(previewBytesCapacity: Int = 2 * 1024 * 1024 * 1024) {
        self.previewBytes = PreviewBytesCache(byteCapacity: previewBytesCapacity)
        self.previewDecoder = PreviewDecoder(bytesCache: self.previewBytes)
    }

    /// Decode `entry.variant` into a `DecodedImage`. Single-flight per
    /// `DecodeKey`: concurrent callers share one decode. The result is
    /// NOT cached on this side — caller is expected to consume the
    /// CGImage inline (upload to `MTLTextureCache.warm`, compute the
    /// histogram, etc.) and let the value drop.
    ///
    /// `.raw` request on an entry with no `rawURL` (standalone HIF /
    /// JPG) silently falls back to `.preview` rather than failing.
    func decode(entry: PhotoEntry, variant: ImageVariant, decoder: DecoderChoice) async throws -> DecodedImage {
        // Resolve the effective variant: .raw without a RAW falls back
        // to .preview. This keeps shortcut keys / auto-swap callers
        // from needing the same guard themselves.
        let effectiveVariant: ImageVariant = (variant == .raw && entry.rawURL == nil)
            ? .preview : variant

        // Decoder is a RAW-only concern: .preview always goes through
        // PreviewDecoder. Normalise the dedup key so preview nav doesn't
        // accidentally fan out across different decoder slots.
        let keyDecoder: DecoderChoice = (effectiveVariant == .preview) ? .imageIO : decoder
        let key = DecodeKey(entryID: entry.id, variant: effectiveVariant, decoder: keyDecoder)

        if let existing = inflight[key] {
            return try await existing.value
        }

        let decoderImpl = decoderFor(variant: effectiveVariant, choice: decoder)
        // `.preview` URL is always present; `.raw` only when rawURL is
        // non-nil (we forced fallback above).
        let url: URL = (effectiveVariant == .preview) ? entry.previewURL : entry.rawURL!

        #if DEBUG
        Log.decode.notice("start: \(key.entryID, privacy: .public) \(key.variant.rawValue, privacy: .public)/\(key.decoder.rawValue, privacy: .public) → \(url.lastPathComponent, privacy: .public)")
        #endif
        let task = Task<DecodedImage, Error> {
            try await decoderImpl.decode(url: url)
        }
        inflight[key] = task
        defer { inflight[key] = nil }

        let result = try await task.value
        #if DEBUG
        Log.decode.notice("done: \(key.entryID, privacy: .public) \(key.variant.rawValue, privacy: .public)/\(key.decoder.rawValue, privacy: .public) in \(result.decodeMS, format: .fixed(precision: 1)) ms")
        #endif
        return result
    }

    private func decoderFor(variant: ImageVariant, choice: DecoderChoice) -> any ImageDecoder {
        switch variant {
        case .preview:
            return previewDecoder
        case .raw:
            switch choice {
            case .imageIO: return rawImageIODecoder
            case .libRaw:  return rawLibRawDecoder
            }
        }
    }
}
