# Video support (Sony A1 II)

**Status:** Discovery — open questions pending answers. No implementation yet.

## Context

Goal: play videos from the camera card alongside stills, with the same optimized
thumbnail / fast-display / zoom / pan feel as photos. Target footage is Sony A1 II
high-bitrate 4K — XAVC HS (H.265/HEVC, 10-bit 4:2:0) in `.MP4` containers,
200–600 Mbps for 4K.

The recent renames (PhotoPair → PhotoEntry, HEIFDecoder → PreviewDecoder,
HIFBytesCache → PreviewBytesCache, PairFinder → EntryFinder, ImageVariant.heif →
.preview) already made the media model format-agnostic — video is the next
variant to slot in.

## What we know

### Codebase readiness
- `PhotoEntry` (`PhotoX/Model/PhotoEntry.swift`) — currently `rawURL` (optional) +
  `previewURL` (required) + `stem`. Needs an optional `videoURL` (or a richer
  `MediaSources` shape) to represent standalone video entries.
- `EntryFinder` (`PhotoX/Loading/EntryFinder.swift`) — recognizes
  `{arw, hif, heif, heic, jpg, jpeg}` grouped by stem. Extension point for
  `.mov / .mp4 / .MOV / .MP4`.
- `ImageVariant` (`PhotoX/Model/ImageVariant.swift`) — hard-coded `.preview | .raw`.
  Needs a `.video` case **or** a parallel `MediaVariant`/`VideoSource` enum.
- `DecodePipeline` (`PhotoX/Decoders/DecodePipeline.swift`) — single-flight dedup
  via `DecodeKey`, `ImageDecoder` protocol pluggable. Video decode is shape-different
  (no single CGImage; time-indexed frames).
- `MTLTextureCache` keyed by `DecodeKey` — video frames could live here keyed by
  `(entryID, .video, time)` if we go the Metal path.
- `PreviewBytesCache` — 2 GB LRU. **Not** suitable for video (4K files > cap);
  video should stream, not buffer whole-file.
- `ImageCanvasNSView` + `CanvasRenderer` (`PhotoX/Canvas/`) — Metal/CAMetalLayer.
  Owns viewport, pinch/scroll/drag/dblclick gestures, EXIF-orientation UV
  rotation, focus peaking / clipping / AF overlays as Metal passes.
- `ViewerState` (`PhotoX/Model/ViewerState.swift`) — @MainActor orchestrator.
  Tracks `currentIndex`, `requestedVariant`, `displayedVariant`, one-way auto-swap
  HEIF → RAW at zoom ≥ 1.0 px (memory: never auto-revert).
- Indexer (`startIndexing` in ViewerState) is the **sole** writer for per-entry
  metadata (memory: extend `MetadataBatchLoader` / add an eager cache; never add
  per-entry `kickOff…Load` methods). Video metadata (duration, codec, bitrate,
  framerate) would route through the same indexer.
- `ThumbnailLoader` + `HEIFEmbeddedThumbnail` — ~5 ms fast path via embedded
  JPEG from HEIF. **No equivalent for MP4** — videos need `AVAssetImageGenerator`
  (~100+ ms per frame) or pre-generated poster frames.
- Card stays strictly read-only (memory): no proxy files written to the card;
  any cache must live under `~/Library/Caches/PhotoX/` (or similar).

### Sony A1 II video specifics
- Containers: `.MP4` (XAVC HS / XAVC S / XAVC S-I).
- Codecs: H.265/HEVC (10-bit 4:2:0) primarily; H.264 alternative.
- Bitrate: 200–600 Mbps for 4K; can exceed 1 Gbps at 8K.
- No embedded thumbnail / poster frame in the MP4 — unlike HEIF, no fast
  "extract a tiny JPEG" path. Sony does **not** write XMP sidecars for video
  on-card; any rating data needs to be written to `<stem>.xmp` next to the MP4.
- File naming: Sony uses `C0001.MP4`, `C0002.MP4` … (separate from `DSC#####`
  stills). Stems generally don't collide with stills — videos are standalone
  entries.

### macOS / Apple Silicon
- M-series Media Engine hardware-decodes H.265 4:2:0 10-bit natively; decode
  is rarely the bottleneck.
- Bottleneck for scrub is seek latency + frame-output buffering, not decode.
- AVPlayer + `AVPlayerItemVideoOutput` → `CVMetalTextureCache` is the standard
  Metal-integrated path. `AVPlayerLayer` is the simpler path.
- ProRes 422 Proxy is the standard editorial-proxy choice; AVAssetWriter /
  VTCompressionSession on Apple Silicon hardware-accelerates encode.

## Open design questions

These need answers before drafting the implementation plan.

### Q1. How should videos be rendered on the canvas?

- **A. Metal via CVPixelBuffer** *(recommended for architectural fit)*
  Pull frames from `AVPlayerItemVideoOutput` into `MTLTexture` via
  `CVMetalTextureCache`; render with the existing `CanvasRenderer`.
  - Pros: one canvas, one gesture model; zoom/pan/clipping/peaking/AF overlays
    reuse for free; viewport continuous across photo↔video navigation; 1:1
    zoom rule stays honest in pixels.
  - Cons: more code (frame-pull loop, frame pacing, audio routing handled
    separately); we own stutter recovery; no free PiP/AirPlay.
- **B. AVPlayerLayer overlay**
  Wrap AVPlayer + `AVPlayerLayer` in a parallel NSViewRepresentable, shown
  when the entry is a video.
  - Pros: ~2 hours of plumbing; vsync + frame pacing + audio + AirPlay/PiP
    free; system-style controls available.
  - Cons: parallel zoom/pan/peaking implementation (or none for video);
    viewport not shared with photo canvas; "1:1" is layer-space.
- **C. AVSampleBufferDisplayLayer**
  CoreMedia direct-feed. Middle ground: better scrubbing control than (B),
  but still no Metal-shader compositing.

### Q2. Do we want a proxy / transcode step?

- **A. No proxies, M-series native** *(simplest)*
  Rely on hardware H.265 decode. Scrub on 4K 200+ Mbps is decent on M-series
  but not photo-instant.
- **B. Lazy ProRes 422 Proxy in cache**
  Background indexer task transcodes to `~/Library/Caches/PhotoX/proxies/`.
  Faster scrub + smaller memory footprint. Adds AVAssetWriter encode + disk.
  Card stays strictly read-only.
- **C. Decide later — start native** *(recommended)*
  Ship native first; design decode layer so a proxy variant can slot in
  later (third `ImageVariant` case or dedicated `VideoSource` enum).

### Q3. Playback / interaction surface for MVP? *(multi-select)*

- **A. Spacebar play/pause + scrubber bar** (timeline + time labels;
  play-icon + duration badge on filmstrip thumbs)
- **B. Zoom & pan during playback** (all photo gestures work on video frames —
  implies Q1=A)
- **C. Frame-step with ⌥← / ⌥→** when paused (find the keeper frame)
- **D. Audio playback** with mute toggle

### Q4. How do videos fit into the filmstrip / culling model?

- **A. Standalone entries, same filmstrip** *(likely default)*
  Each `.MP4` is its own `PhotoEntry` with `videoURL` set; interleaved with
  stills, sorted by name/mtime. XMP sidecar drives rating/reject like stills.
- **B. Filter toggle (photos / videos / all)**
  Same as (A), plus a filmstrip-top toggle. Useful when both are dense.
- **C. Group video with same-stem still**
  Probably not relevant for A1 II — videos use `C00xx.MP4`, stills use
  `DSC#####`, so stems don't collide.

## Detailed pros/cons captured for Q1 option A (Metal/CVPixelBuffer)

**Pros**
- One canvas, one gesture model — `ImageCanvasNSView` + `CanvasViewport` own
  pinch / ⌘+scroll zoom / dblclick fit↔1:1 / drag-pan; video frames become
  "just textures."
- Overlays reuse for free — clipping, peaking, AF regions, histogram are
  Metal passes over `baseTexture`.
- Continuous viewport across photo↔video navigation (zoom/offset preserved).
- HEIF→RAW one-way auto-swap pattern generalizes to a future video proxy
  variant (same Metal cache, different texture under the same key shape).
- Color management unified — `CVMetalTextureCache` keeps the renderer's color
  path; same pixel format selection.
- 1:1 zoom = native pixels works identically for a 4K frame and a 50 MP RAW.

**Cons**
- More code up front: `AVPlayerItemVideoOutput` wiring, display-linked draw
  loop driven by `itemTime`, `CVMetalTextureCache` integration, frame pacing,
  actor/queue bridging AVFoundation callbacks → @MainActor renderer.
- Audio routing handled separately (AVPlayer still does it fine without
  `AVPlayerLayer`, but no "everything just works" `AVPlayerViewController`).
- No free transport controls / PiP / AirPlay — hand-rolled scrubber.
- Frame pacing is on us (drops, stutter recovery); buggy here = microstutter.
- Extra texture upload per displayed frame (CVPixelBuffer IOSurface-backed,
  so cheap, but not zero). Fine for 4K30; careful at 4K120.
- Scrub *feel* (small frame-step on drag, large seeks on flick) is on us.

## Reading list (files referenced when planning continues)

- `PhotoX/Model/PhotoEntry.swift`
- `PhotoX/Model/ImageVariant.swift`
- `PhotoX/Model/ViewerState.swift` (especially `startIndexing`, `applyRequestedVariant`)
- `PhotoX/Loading/EntryFinder.swift`
- `PhotoX/Shoot/ShootScanner.swift`
- `PhotoX/Decoders/DecodeKey.swift`
- `PhotoX/Decoders/DecodePipeline.swift`
- `PhotoX/Decoders/PreviewDecoder.swift`
- `PhotoX/Decoders/PreviewBytesCache.swift`
- `PhotoX/Canvas/ImageCanvasView.swift`
- `PhotoX/Canvas/ImageCanvasNSView.swift`
- `PhotoX/Canvas/CanvasRenderer.swift`
- `PhotoX/Canvas/CanvasViewport.swift`
- `PhotoX/Canvas/MTLTextureCache.swift`
- `PhotoX/Filmstrip/FilmstripView.swift`
- `PhotoX/Filmstrip/ThumbnailLoader.swift`
- `PhotoX/Metadata/MetadataBatchLoader.swift`
- `docs/plans/jpg-support.md` (prior rename initiative; same pattern)

## Next steps

1. Answer Q1–Q4 above.
2. Pick a render path and write the implementation plan: entry-model shape,
   decode-pipeline extension, video thumbnail loader, indexer integration,
   canvas swap or merge, scrubber UI, playback state in `ViewerState`, XMP
   rating parity, tests.
3. Decide cache layout for any future proxies (under `~/Library/Caches/PhotoX/`).
4. Verify Sony A1 II XMP sidecar conventions for video ratings in Lightroom
   before committing to a culling-data shape.
