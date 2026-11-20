# AGENTS.md — nap-app

Field notes and non-obvious traps discovered while working on `nap-app`. Read this first to avoid re-investigating solved problems.

## Build, Test, and Sandbox Gotchas

- **SwiftPM fails inside nested sandboxes**: `swift build` and `swift test` invoke `sandbox-exec` when compiling `Package.swift` manifests, which fails with `sandbox-exec: sandbox_apply: Operation not permitted` inside restricted agent sandboxes. Run `swift build`, `swift test`, and `./scripts/build-app.sh` outside the sandbox (`required_permissions: ["all"]`).
- **Avoid parallel `swift build` calls**: SwiftPM locks `.build/`. If parallel subagents edit Swift files, have them edit disjoint files without compiling, then run `swift test` once from the parent session.
- **Platform floor is macOS 14 (`Package.swift`)**: Do not use macOS 15+ SwiftUI modifiers (e.g. `.pointerStyle`). Stick to macOS 14-compatible SwiftUI + AppKit APIs.
- **Headless UI verification**: `NapApp` supports `--snapshot OUT.png [--batch NAME] [--anchor X,Y] [--ingest ROLL_DIR]` (`Sources/NapApp/Snapshot.swift`), rendering the window directly via `cacheDisplay` without needing Screen Recording permissions.

## Vision Optical Flow & Alignment

- **Never upgrade `VNGenerateOpticalFlowRequest` to Revision 2**: `Alignment.swift` intentionally pins `VNGenerateOpticalFlowRequestRevision1`. Revision 2 shrinks displacements 3–5× on grainy film scans and adds an ~11s model load penalty; Revision 1 is accurate within ~0.1px.
- **Optical flow sign convention**: `VNImageRequestHandler` runs on `reference` with `targetedCGImage: target`. Content that shifts by `(+dx, +dy)` from `reference` to `target` reads as `(+dx, +dy)` flow (pinned by `FlowTests.flowPointsFromReferenceToTarget`).

## Coordinate Spaces (`WiggleView` vs `anchors`)

- **`anchors` live in full uncropped source space, NOT cropped wiggle space**:
  - `PipelineOptions.anchors[i]` (and `AnchorStore`) stores normalized `0...1` coordinates (top-left origin) on `sources[i]` (after `ImageLoader.normalizeSizes`).
  - `AlignedBatch.alignedFrame(0)` crops `sources[0]` to `CGRect(x: Int(crop.minX) - offsets[0].x, y: Int(crop.minY) - offsets[0].y, width: Int(crop.width), height: Int(crop.height))`. When `centerSubject` is enabled, `offsets[0]` is frequently hundreds of pixels off zero.
  - Clicking on the aligned `WiggleView` MUST transform through `AlignedBatch.sourceAnchor(fromAlignedPoint:)` (and inverse `alignedPoint(fromSourceAnchor:)` for rendering indicators), never raw `(x / viewWidth, y / viewHeight)`.
  - `BatchSession.apply` updates `aligned` and `preview` atomically on `@MainActor`, so `session.aligned` always matches the currently displayed `session.preview` even while a new alignment is in flight.

## Nimslo Flicker & Lab Scanner Physics

- **Why Nimslo scans strobe at 10 Hz**:
  - Across the 4 lenses (and half-frame lab scan pairs `N` vs `NA` on Noritsu/Frontier scanners), frames frequently alternate `1 & 3` vs `2 & 4` in exposure, per-channel RGB auto-balance, and **shadow floor pedestal (`Dmin`)**.
  - Because boomerang playback (`1→2→3→4→3→2` at 10 fps) steps through alternating frames, a `1-3` vs `2-4` mismatch flips polarity on *every single frame transition* (a 5 Hz full-cycle / 10 transitions-per-second strobe right at peak human flicker sensitivity).
- **Why scalar Lab `L*` mean scaling fails**:
  - Underexposed negatives scanned on Noritsu/Frontier sit on a flat gray/tinted shadow pedestal (`~15–45 / 255` where `p1 ≈ p2 ≈ p5 ≈ p10`), while `p99` highlights often remain pinned near `245–250 / 255`.
  - Multiplying `L*` by `target / mean` lifts crisp dark shadows on good frames into milky gray, clips highlights when brightening, and leaves per-channel RGB color casts untouched (often making chroma flicker *worse*).
  - **Fix (`Exporter.gradeFrames`)**: Per-channel quantile tone-curve matching over the interior 90% of the crop, anchoring shadow quantiles (`p < 0.25`) toward the **crispest lens in the batch** (`min` blending smoothly to `median` by midtones) so washed-out sibling lenses pull down to clean blacks instead of lifting good frames, paired with a smooth neutral shadow toe (`blackPoint`) to seat scanner `Dmin` haze without darkening intentional high-key/pastel scenes.
- **Instant UI re-grading**: `BatchSession` caches `ungradedPreview` (`1200px` cropped frames) so adjusting `gradeStrength` or `blackPoint` re-runs LUT grading in a few milliseconds without re-running Vision segmentation or optical flow.
- **One hot batch**: `AppModel.sessions` keeps `AlignmentGeometry` (offsets, crop, sizes, reports, subject centers) for every opened batch and bitmaps only for the focused one. Full scans are decoded to build the 1200px preview or an export, then released. Returning calls `NapPipeline.reload` and skips Vision. The brown mask overlay comes back only on a full align; the `+` uses the stored center.

## Batch Numbering & Print Stills

- **Batch folder ordering**: Numbered scan folders in `NAP_INPUT_DIR` increment sequentially (`20..180+`; folders `01..11` in older archives may hold `<3` files and are skipped by `BatchScanner.batch(at:)`). `BatchScanner.batches(in:)` sorts descending so newest rolls appear at the top of the sidebar.
- **Print stills fidelity**:
  - The library is one folder per batch number (`NAP_GIF_OUTPUT_DIR/176/` holds `176.gif`, `176.mp4`, and `01_…` stills). `ExportTargets.bundle` is the shared layout for the app and `nap-swift`.
  - Print stills (`Exporter.writeStills`) are full-resolution shared crops of the source scans with a subtle bottom-right frame dot pager (`StillFrameMarks`). They run through the same `gradeLUTs` as the wiggle. 16-bit scans stay 16-bit: the 8-bit sRGB curve is resampled with `applyLUT16` instead of quantizing to 256 levels.
  - `ImageLoader.load` and `StillFrameMarks` must preserve native 16-bit depth (`bitsPerComponent > 8`) and native `CGColorSpace` (`kCGImageDestinationOptimizeColorForSharing: false`, JPEG quality `1.0` 4:4:4, lossless PNG/LZW TIFF). Avoid `CGImageSourceCreateThumbnailAtIndex` for full-res orientation transforms because it can down-convert 16-bit images to 8-bit.
