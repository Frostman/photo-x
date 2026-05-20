import Foundation

/// Cache key shared by `DecodePipeline.inflight` and `MTLTextureCache`.
/// Entry-id + variant (preview vs RAW) + decoder choice fully identify
/// a pipeline output: two callers requesting the same key get the same
/// decoded image (single-flight) AND, downstream, the same GPU texture.
///
/// `decoder` is normalised at the call site for `.preview` so the same
/// preview file doesn't get two cache entries under different decoder
/// slots — only RAW variants actually differ by decoder.
struct DecodeKey: Hashable, Sendable {
    let entryID: String
    let variant: ImageVariant
    let decoder: DecoderChoice
}
