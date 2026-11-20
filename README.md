# nap

a mac app for aligning four-lens scans into wigglegrams. macOS 14 or later, Apple silicon.

## build

```bash
./scripts/build-app.sh
open build/Nap.app
```

that build is ad-hoc signed, so it opens on the machine that built it. `./scripts/build-app.sh --install` also copies it to `/Applications`.

building needs the Swift 6 toolchain (Xcode 16 or later). the icon is rasterized from `assets/nimslo-suns.svg`, which needs `rsvg-convert` or ImageMagick. `swift test` runs the unit tests.

## use

⌘O opens one batch, or a folder of numbered batches. batches sort newest first in the sidebar. ⌘I ingests a developed roll: drag frames between batches, then import. in a batch, click the wigglegram or a frame tile below it to pin the focal subject (pin frame 1 and the rest follow; ⌥-click clears it). space opens a sharper view, and dragging a frame sideways reorders the lenses. live grade evens out lens exposure and color so the wiggle doesn't flicker, and keeps the blacks sharp (`NAP_GRADE_STRENGTH` and `NAP_BLACK_POINT`, or `--grade` / `--blacks`). print stills get that same grade. ⌘E exports the open batch as gif + mp4. ⌘⇧E exports whatever is selected in the sidebar.

## folders

copy `.env.example` to `.env` and point it at your scans. settings (⌘,) reads and writes that file: the scan folder, the library, plus quality, grading, mp4 loops, and subject centering. the first edit adds the app keys under your existing paths. `choose…` on the saved-in row points the app at a different file.

each batch is one folder in the library, named like the scan folder. `176/` holds `176.gif`, `176.mp4`, and the full-resolution stills (`01_…`, three or four of them). stills are exposure-matched with the same curves as the wiggle.

```dotenv
NAP_INPUT_DIR=~/path/to/scans
NAP_GIF_OUTPUT_DIR=~/path/to/wigglegrams

# NAP_QUALITY=best
# NAP_MP4_LOOPS=1
# NAP_CENTER_SUBJECT=true
# NAP_GRADE_STRENGTH=0.90
# NAP_BLACK_POINT=0.35
```

`.env` is gitignored.

## cli

`nap-swift` is the command-line build of the same pipeline. `./scripts/build-app.sh` prints its path.

```text
nap-swift BATCH_DIR [-o OUT.gif|OUT.mp4] [--format gif|mp4|both|stills] [--stills]
                    [-q fast|balanced|best] [--anchor X,Y] [--loops N] [--no-center]
                    [--grade 0.90] [--blacks 0.35]
nap-swift START END [--stills] [--loops N]
nap-swift ingest ROLL_DIR [INTO_DIR] [--dry-run] [--move]
```

range mode and `ingest` without `INTO_DIR` use the `NAP_*` paths from `.env` or the environment. without `-o`, a batch lands in `NAP_GIF_OUTPUT_DIR/<name>/`. `--anchor` is normalized 0...1 from the top-left of frame 1. `--grade` and `--blacks` are 0...1 (`NAP_GRADE_STRENGTH`, `NAP_BLACK_POINT`): they even out lens exposure and color, and keep the blacks sharp. stills take those same curves. `--stills` writes them into the batch folder.

## license

mit. see `LICENSE`.
