# de-flickering nimslo scans (`Exporter.gradeFrames`)

a quick field guide to why 4-lens half-frame film scans flicker so aggressively, why standard brightness normalization makes them look worse, and how `Sources/NapCore/Export.swift` fixes it.

---

## 1. the physical problem: why nimslo scans strobe at 10 hz

when we profiled real nimslo rolls (`20–180`), three scanner + camera behaviors showed up together:

1. **odd/even lens alternation (`1 & 3` vs `2 & 4`)**:
   between slight per-lens shutter/aperture tolerances on the nimslo and how commercial lab scanners (noritsu / frontier) pair or step half-frames (`N` vs `NA`), frames rarely drift monotonically. instead, lenses `1 & 3` vs `2 & 4` systematically alternate.
   because a boomerang loop (`1 → 2 → 3 → 4 → 3 → 2` at 10 fps) steps odd → even → odd → even, **every single frame transition flips polarity** — a 10 transitions/sec strobe right at peak human flicker sensitivity.
2. **scanner `Dmin` shadow pedestal**:
   when a lens is slightly underexposed, the lab scanner tries to "save" shadow detail by lifting the black floor (`Dmin` / film base + fog) into a flat milky gray shelf around `20–45 / 255` (where `p1 ≈ p2 ≈ p5 ≈ p10`), while highlights (`p99`) remain pinned near `245 / 255` on *every* frame.
3. **independent RGB auto-balance**:
   each half-frame scan gets its own automatic color balance, so R, G, and B drift separately (e.g., warm shadows on lens 1, cyan/green cast on lens 2).

---

## 2. why "scale brightness toward the mean" fails

the textbook approach is converting to Lab lightness (`L*`) and multiplying each frame by `targetMean / frameMean`. on negative film scans, a single scalar multiplier breaks both ends of the tonal range:

- **brightening a dark frame** (`k > 1`) multiplies its shadow floor upward (`20 → 30`) and clips `245` highlights into `255`.
- **meeting at the mean** pulls crisp dark lenses *up* halfway toward foggy lenses instead of pulling foggy lenses *down* to clean black — leaving the whole batch washed out.
- **touching only luminance** leaves RGB channel offsets intact (or exaggerates chroma swings when scaling).

---

## 3. the fix: per-channel CDF quantile matching + asymmetric shadow anchor

across 4 lenses spaced ~55 mm apart looking at the same scene, the **interior 90%** of the aligned crop sees essentially the same physical distribution of shadows, midtones, and highlights.

instead of matching *averages*, `Exporter.gradeFrames` matches the **cumulative distribution function (CDF)** of R, G, and B independently across 17 percentile knots:

```
p ∈ [0.0, 0.005, 0.01, 0.02, 0.05, 0.10, 0.20, 0.35, 0.50,
     0.65, 0.80, 0.90, 0.95, 0.98, 0.99, 0.995, 1.0]
```

### step a — sample interior histograms
we build 256-bin R, G, B, and luma histograms over the middle `90% × 90%` of each cropped frame (`x0 = w / 20 .. w - w / 20`) so black film rebate or light-leak edges never skew the curve, then compute continuous interpolated quantiles `q[frame][channel][k]`.

### step b — asymmetric target across lenses (crisp blacks win)
for each channel `c` and quantile knot `p = knots[k]`, we compute both the **median** (`med`) and **minimum** (`mn`) across the 4 frames:

- **midtones & highlights (`p ≥ 0.25`)**: target is `med`. exposure and RGB color casts lock together without letting one outlier frame drag the batch, and `p99` stays unclipped.
- **shadows (`p < 0.25`)**: target blends smoothly from `med` toward `mn`:
  ```
  wDark = (1 - p / 0.25)^1.5      (for p < 0.25, else 0)
  baseTarget = wDark * mn + (1 - wDark) * med
  ```
  in plain english: *whichever lens captured the cleanest, deepest black sets the shadow floor for the whole wigglegram; milky sibling lenses get pulled down to meet it.*

each frame blends toward `baseTarget` by `matchStrength` (`NAP_GRADE_STRENGTH`, default `0.90`):

```
value = src + matchStrength * (baseTarget - src)
```

### step c — neutral `blackPoint` shadow toe
even the sharpest lens on an underexposed roll can carry residual scanner base fog. we estimate that shared pedestal from the darkest lens's `0.5%` luma quantile (`minLumaP05`), cap it so intentional bright/pastel scenes aren't crushed, and pull only the shadow toe (`value < 140`) down **equally across R, G, and B** so shadows never pick up a color tint:

```
pedestal  = min(minLumaP05, 36 * (0.4 + 0.6 * blackPoint))
pull      = pedestal * 0.80 * blackPoint
toeWeight = ((140 - value) / 140)^2     (for value < 140, else 0)
dst       = max(0, value - pull * toeWeight)
```

### step d — monotonic 256-byte LUTs (fast live scrubbing)
for each frame and channel:
1. merge plateau knots within `0.25` code values and enforce monotonicity (`dst[k] >= dst[k - 1]`) so gradients never invert or posterize.
2. clamp tail slopes (`0.4 ... 2.2`) and run a gentle 5-tap smoothing kernel (`[1, 2, 4, 2, 1] / 10`) on interior entries `1..<255` so 8-bit histograms don't band.
3. apply `[lutR, lutG, lutB]` across the 4 frames in parallel.

because `BatchSession` caches the ungraded `1200px` aligned preview frames (`ungradedPreview`), dragging `exposure & color match` or `black point` in the app only recomputes and applies twelve `256`-byte LUTs (~2 ms total) — no Vision segmentation or optical flow re-run needed.

---

## 4. where it lives in code

- **core algorithm**: `Sources/NapCore/Export.swift` → `GradeSettings`, `Exporter.gradeFrames(_:grade:)`. print stills call the same `gradeLUTs` (16-bit scans resample the curve instead of dropping to 8-bit).
- **instant preview cache**: `Sources/NapApp/AppModel.swift` → `BatchSession.ungradedPreview`, `BatchSession.regrade(_:)`
- **controls & config**:
  - toolbar popover: `Sources/NapApp/BatchDetailView.swift` (`GradePopoverView`)
  - settings (`⌘,`) & `.env`: `NAP_GRADE_STRENGTH` (`0.90`), `NAP_BLACK_POINT` (`0.35`)
  - CLI (`nap-swift`): `--grade 0..1` and `--blacks 0..1`
- **unit tests**: `Tests/NapCoreTests/NapCoreTests.swift` (`GradingTests`)
