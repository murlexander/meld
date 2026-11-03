# Verification

## Version 0.6 — 30 October 2026

298 rendering and session checks passed on the merged optimized build: the 224 earlier checks, 20 for the concurrent pipeline (below) and 54 for the 0.6 workflow. Product checks cover kept picks across sets and unique numbering, grid order, keyboard selection across rows and clamped columns, F/D picks, hidden-selection recovery, previous/next in refinement (including with Picks shown and after unpicking the open preview), thumbnail sizes without touching saved preferences, Values and Notan studies that never change the artwork, palette extraction and hex values, variations (12 distinct, same recipe and shape, from refined adjustments, reproducible by seed, made with the source folder disconnected, cancellable), unique export names across rows, Copy Image on a private pasteboard, and drag-out files at 2400 pixels.

Merged build, `Meld --benchmark`, median of three runs, same Mac:

| Operation | Fuji JPEG + RAF | Canada JPEG |
| --- | ---: | ---: |
| First preview | 0.38 s | 0.20 s |
| All 36 previews | 1.73 s | 0.59 s |
| Export 6 picks and contact sheet | 0.62 s | 0.62 s |
| 12 variations | 0.05 s | 0.07 s |
| Peak memory footprint | 1.22 GB | 1.13 GB |

Baseline before both changes: 1.07 s, 4.75 s and 1.64 s on the Fuji folder at a 1.83 GB peak. Runs sample sources at random and other work on the Mac adds noise.

The interface was checked with `--ui-snapshot` in light and dark appearance: source selection, a grid with two rows, a variations row, refinement with palette and View control, and Notan. An independent code review found no high-severity issues; its seven medium/low findings (hidden selections driving commands, F/D/V with Caps Lock or a Russian layout, navigation resetting panels, scroll-to-selection, column counting with scrollers, Esc while renaming a layer, ⌘+ without Shift) were fixed. Live pointer, drag-and-drop into other apps, and menu interaction were not exercised; snapshots don't render Liquid Glass.

## Performance update — 30 October 2026

All 244 rendering and session checks passed on the optimized build, and 256 with the public Nikon NEF fixture (`MELD_RAW_FIXTURE`). The 224 earlier checks are unchanged; 20 new checks and waits cover the concurrent pipeline. Recipes, seeds, 480-pixel previews, 2400-pixel PNG exports, contact sheets, cancellation and late-callback guarantees are unchanged. Source files were only read.

Measured with `Meld --benchmark` on Apple M2 Pro / 16 GB, macOS 27.2. Each figure is the median of three processes × three runs, run interleaved with a build of the previous commit (fba8664). Peak footprint comes from `/usr/bin/time -l` on one run, measured three times. Each run samples sources at random, so individual runs vary, and other work on the Mac added noise.

September shoot (23 Fuji shots, 40 MP JPEG + RAF, 2.2 GB):

| Operation | Before | After |
| --- | ---: | ---: |
| First preview | 1.05 s | 0.37 s |
| All 36 previews | 3.63 s | 1.60 s |
| Open a preview | 51 ms | 36 ms |
| Export 6 picks and contact sheet | 1.51 s | 0.52 s |
| Peak memory footprint | 1.80–2.14 GB | 1.14–1.20 GB |

Canada previews (16 JPEGs):

| Operation | Before | After |
| --- | ---: | ---: |
| First preview | 0.30 s | 0.13 s |
| All 36 previews | 1.49 s | 0.45 s |
| Export 6 picks and contact sheet | 1.50 s | 0.53 s |

The first generation after launch is slower, because the first RAW development in a process costs about 0.55–0.6 s. Cold first runs on the Fuji folder took 0.46–0.77 s to the first preview and 1.6–2.0 s for all 36, versus 0.76–1.28 s and 2.6–3.9 s before.

Where the time went before: decoding was about 85% of generating 36 previews. A 40 MP JPEG takes about 150 ms to reach 2400 pixels; a RAF took 370–480 ms. Rendering a 480-pixel preview takes 3–20 ms, a 2400-pixel export 35–110 ms, and PNG compression about 180 ms per export. Everything ran one item at a time.

- **Mirrored tiles** made Core Image hold the whole mirrored cell at source resolution (up to 4800 × 3200, even for a 480-pixel preview). Twelve Tiles previews added 1.6 GB of footprint with the Fuji JPEGs and 2.8 GB with synthetic sources; other styles stayed flat. The cell is now scaled to its on-canvas size, in whole pixels, before mirroring and tiling. Placement is the same and Tiles previews render about 4× faster. Output differs only by resampling order (mean 3–5/255); preview and export renders were inspected side by side. A new check bounds the footprint of twelve tiled previews; the old renderer grew by 2.76 GB on the same check.
- **RAW development** ran under the 128 MB render-task memory target. Core Image then developed the RAW in tiles, taking about 2× longer and leaving a higher footprint (1.46 vs 0.99 GB after eight RAFs). The decoding context no longer has a target. Developed pixels are effectively unchanged (mean difference 0.002/255). Render contexts keep the 128 MB target. The first RAW development in a process adds a fixed ~600 MB, independent of concurrency.
- **Decoding** now runs three at a time, ahead of rendering (`Sources/Pipeline.swift`). The pool keeps sampled order: each group gets exactly the first 3, 5, 7… usable candidates, as a one-at-a-time decode would. No more than 12 decodes succeed, and unreadable files are counted as before.
- **Previews** render three at a time on the shared batch context and are delivered in number order. The first group of six still appears early, and the first result still clears the previous set.
- **Batch export** encodes up to four PNGs at a time with ImageIO (same bytes as `NSBitmapImageRep`), while their 2400-pixel renders take turns. The Flow displacement map is enlarged by Core Image instead of a CPU-side 2400-pixel copy (35 ms and 23 MB per export; mean difference about 1/255). Cancellation still stops new work and is checked before encoding and before writing.
- The export folder name sets `en_US_POSIX`, so a 12-hour clock setting no longer produces names like “5.34.34 PM”.

New checks: ordered delivery and stopping of concurrent work; the ordered, bounded material pool with unreadable files; cancelled gathering; tiled-preview footprint; tile layout at both sizes; full-size wave map; progressive, numbered, distinct and balanced concurrent previews; parallel export identical to serial rendering (max one level per channel) in chosen order; mid-batch export cancellation with no late writes; and 24-hour folder names.

Tried and not kept:

- One RAW development at a time, with JPEGs alongside: slower in a controlled A/B over six fixed samples (cold all-36 median 1.77 s vs 1.18 s). Earlier slow outliers came from other load on the Mac.
- Four decode workers: no faster than three for all 36, slower first previews, and up to 90 MB more footprint. Two workers were slower.
- More preview renders at once: little effect on the Fuji folder, where decoding is the limit. Three beat one on the Canada folder (0.44 vs 0.53 s).
- Six exports at once: 0.43 s for 6 picks, but exporting all 36 picks peaked at 2.4–2.6 GB. Four at a time, with renders taking turns, exported 36 picks in 2.6–2.9 s at a 1.78–2.0 GB peak. The previous serial code took 8.7–8.9 s and peaked at 2.14–2.24 GB on the same workload.
- PNG row filters: none was faster than the default adaptive filter (174–235 ms vs 186 ms), and several made larger files.
- Decoding a smaller working copy first and the 2400-pixel copy later: RAW development costs about the same at 1000 pixels (~370 ms), and a later decode would reread sources after loading. That would break the guarantee that exports are independent of the source folder once loaded.
- A half-float working format for RAW development: no gain.

Profiling helpers and logs are in `/private/tmp/meld-perf-prof/`; the NEF fixture was downloaded to `/private/tmp/meld-perf-raw-fixture/` only. The GUI was not launched or installed.

## Performance update — 7 October 2026

236 rendering and session checks passed on the final local build, including the public Nikon NEF fixture and 40 additional checks/waits covering the performance changes. The original 196 checks continue to pass. Product code was built with the normal optimized arm64 build. The temporary signed bundle passes strict signature verification, and its executable hash matches the local `Meld.app`. Finder/iCloud can reattach metadata to the local app after a successful verification; the signed staging copy printed by `build.sh` stays outside that directory. The installed app and running session were not replaced or restarted.

- Recipes, originals, edits and undo share immutable decoded source images; there is no unbounded global cache or intermediate PNG compression during import. Full working images remain bounded to 2400 pixels for generation, 3200 for direct import. Reusable 1000-pixel sources serve the gallery and adjustment drafts; small sidebar thumbnails avoid repeated decoding in view bodies.
- The first group of six renders after three usable sources, then the pool grows to at most 12. All 36 previews, balanced styles, source preservation, corrupt input handling, failure preservation, stars, edits and contact sheets still pass. Each generation rescans the folder to include files added since selection.
- Continuous adjustment tests publish multiple previews during a gesture and settle to the latest pixels at 1000 pixels, or 2400 when magnified. Navigation resets Fit resolution and rejects results from previous refinement visits; comparison likewise rejects pending adjustment drafts.
- Single and batch exports use their own serial queue and renderer. Tests verify export snapshot accuracy while adjustments continue, cancellation, and contact sheets containing completed exports. Obsolete folder scans and material gathering now honour cancellation.
- Wide-gamut RGB colour and partial/transparent alpha survive preview resizing. RAW gallery rendering does not replace the developed export source, and RAW rendering/export remains valid after removing a temporary copy of its source file. Embedded camera previews remain a fallback, not a different-colour primary path.
- Core Image renders are materialized on their worker queues. Contexts use a 128 MB render-task memory target, disabled intermediate caching, and release batch/export caches after completion. Decoded source retention trades some memory for speed: measured whole-process peak footprints were about 1.37 GB for synthetic material and 1.71 GB for the repeated-NEF set, versus 1.25/1.45 GB before. The task memory target is not a total process cap. The uncapped faster implementation peaked near 2–2.7 GB in these runs and was not retained.

Bounded timings on Apple M2 Pro / 16 GB, macOS 27.0.1, optimized builds with normal graphics access and warm filesystem caches:

| Actual model operation | Before | After |
| --- | ---: | ---: |
| First preview, 12 synthetic 2400×1600 JPEGs | 3.36 s | 0.22 s |
| All 36 previews, synthetic | 8.22 s | 0.91 s |
| First preview, 12 paths to the public NEF | 3.57 s | 0.49 s |
| All 36 previews, NEF paths | 7.46 s | 1.67 s |
| Six PNGs and contact sheet, synthetic | 2.46 s | 1.79 s |
| Six PNGs and contact sheet, NEF paths | 1.85 s | 1.37 s |

The RAW workload uses twelve paths to the same public fixture, not twelve distinct cameras or photographs. Recipes in model runs are randomized; these are bounded observations, not universal speed guarantees. About 21 draft renders completed during each one-second continuous slider test, versus no preview updates during the earlier trailing debounce. Final image settling was approximately 128–208 ms. An isolated queue check found comparable preview latency with and without a simultaneous single-image export; the earlier implementation approximately doubled it.

Synthetic and RAW contact sheets were visually inspected. Desktop inspection was attempted again and still failed with ScreenCaptureKit error -3811, so a live pointer/keyboard walkthrough remains unverified. Native controls and layout are preserved. Profiling helpers, source fixtures, timings and test logs are confined to `/private/tmp/meld-performance-implementation/`; earlier baseline evidence remains in `/private/tmp/meld-perf-review.JDphAh/`.

The build script now verifies the staged signature and removes leftover Finder/resource-fork metadata from the generated local app copy. Finder/iCloud reattached metadata during verification, so this cleanup is not a persistent fix for cloud-managed directories. Use the signed staging copy printed by the build script when verifying or distributing the app.

## Automatic playground — version 0.5, 7 October 2026

196 rendering and session checks passed with the real Nikon NEF fixture enabled. The default session now follows source folder → 36 previews → refine and export picks. The gallery occupies the main window. Refinement offers distortion, pattern amount, colour, and contrast; the existing layer workspace is available through More controls. The established native toolbar, teal accent, and floating zoom controls remain.

- A session starts at source selection without a sample canvas. The remembered source is not scanned until requested. Square, portrait, and landscape are available before generation.
- All 36 previews are distinct, with six of each composition style. Recursive folders, corrupt-file handling, unchanged source bytes, and a real Nikon NEF-only batch are covered.
- Each preview retains its own adjustments. Navigation starts a separate undo history; undo/redo also restores refinement sliders. Reset and comparison use the generated original.
- Picked PNGs export at 2400 pixels on the longest side. Their pixels match the stored adjustments. The exported contact sheet uses freshly rendered adjusted images, even when the gallery thumbnail is stale.
- Cancellation preserves the previous set before the first result, or retains completed previews afterward. Refinement waits until generation finishes or stops, preventing a replaced preview from remaining active.
- Empty or unavailable folders preserve the previous set. The session remains temporary: export picks before replacing the set or closing Meld.

Synthetic and real-RAW contact sheets and adjusted exports were visually inspected. Core Image checks require the normal macOS graphics services outside the terminal sandbox. The desktop inspection service returned ScreenCaptureKit error -3811 during this session, so a complete live pointer/keyboard walkthrough remains unverified.

Version 0.5 was installed in `~/Applications/Meld.app`. Its ad hoc signature verifies, and the installed executable hash matches the tested build. Version 0.4 is retained in `Reference/Backups/Meld-before-workflow-0.4.app`; installation did not quit the running session. Reopen Meld after exporting current work to use the new workflow.

The current live smoke pass, when desktop inspection is available:

1. Choose a folder; change format and generate 36 previews.
2. Star previews and filter picks. Open a preview, adjust all four controls, compare, reset, and undo.
3. Return to the gallery, open another preview, then reopen the edited one.
4. Export picks through the folder panel and inspect both PNGs and contact sheet.
5. Generate a new set, stop partway, and refine a completed preview.
6. Check More controls, inspector recovery, zoom, and light/dark appearance.

## Earlier verification — 6 October 2026

The earlier audit passed 139 rendering and session checks, including a real Nikon NEF fixture. After adopting option 5, the standard rendering and session suite was rerun successfully; the optional real-RAW fixture was not repeated for this layout change. Fixtures and generated output are not bundled or committed.

## Generator update — version 0.4

178 checks passed with the real Nikon NEF fixture enabled. The generated 24-image contact sheets were inspected for composition variety using both synthetic material and a RAW-only source folder.

- A batch generates 24 distinct previews, with four examples of each of the six styles. Trials retain their editable source layers and the current canvas shape.
- Creating trials leaves the working canvas, layer selection, revision, and undo history unchanged. Opening a trial restores its layers, disables comparison, selects an image layer, and supports one-step undo/redo.
- Favourite selection, 2400-pixel portrait exports, and a contact sheet of the exported selection were checked. Batch export creates a unique subfolder.
- Immediate cancellation preserves the previous batch and favourites. Midway cancellation retains completed trials and rejects late callbacks. Disconnecting a source cancels generation. Empty or unavailable folders retain the previous trials.
- Corrupt files are skipped, nested sources are included, and all source bytes remain unchanged. A single real NEF produced 24 different trials.
- Mirrored image tiling and deterministic recipe reproduction were checked. Noise cell geometry now stays consistent across preview and export resolutions; colour checks allow one channel value of raster rounding.

Core Image cannot render inside the current terminal sandbox. Checks were therefore run with access to the normal macOS graphics services. The preview-resolution check uses the size of its CGImage-backed NSImage: obtaining a display CGImage can resample it for Retina and report a different size.

The new review sheet preserves the main app layout and uses native controls. The desktop inspection service still returns ScreenCaptureKit errors, so a complete live pointer/keyboard walkthrough of the gallery and native export panel remains pending. SwiftUI ImageRenderer can show the sheet header and detail pane but omits its native scroll view; that partial snapshot was not treated as gallery verification.

The final desktop connection reported that the Mac was locked. The 0.4 app was installed and its signature and executable hash verified against the tested build. The previous installed app was retained in `Reference/Backups/`; this update did not quit the running Meld session.

| Requested behavior | Implementation and verification |
| --- | --- |
| Comfortable native controls and familiar left panel | Layers, source folder, patterns, and Surprise me remain in the sidebar; regular/large native controls and macOS 26 glass styles with older-system fallbacks. |
| Restrained teal accent | Adaptive teal for app actions and zoom; ordinary glass buttons are neutral. Native system selection styling can still follow macOS appearance. |
| Icon-only toolbar, separate undo/redo group | Native navigation sidebar and system toggle restored. Undo/redo, comparison, and far-right Export use native toolbar spacers. Approved Lab option 5 uses a native sidebar and inspector with automatic full-height material. No forced toolbar background or artwork extension; toolbar size remains regular. Comparison and inspector visibility share a group. |
| Export only; no saved projects | No Save command, document type, restoration of artwork, or save-on-close prompt. PNG export validated at 2400 pixels on the longest side. |
| Add images in Layers | Button beside the Layers heading; image-import model tested. |
| Recoverable right controls (updated request) | Native inspector opens visible. A writable presentation binding connects divider collapse and the toolbar Show controls / Hide controls toggle. |
| Drag layers; remove action strip | Native List reordering; model order and undo/redo tested. Duplicate and Remove remain in the context menu. |
| Always include subfolders | Recursive scanning and mixing from images two folders deep tested; no checkbox. |
| Before distortions in toolbar | Toolbar toggle; renderer comparison validated for effects. |
| Floating glass zoom over the canvas | Fit, logarithmic slider, and percentage sit in a glass capsule over the full-height canvas, with no reserved bottom strip; scrolling and pinch handling remain available. Pixel geometry and full-resolution magnified previews tested. |
| Double-click sliders to reset | Native double-click handling; all declared defaults checked against the model. Zoom reset returns to Fit. |

## Fix found during the audit

Rapid Duplicate or Remove commands previously shared an undo step. Each command now creates its own undo entry. Visibility clicks also use independent entries. Regression checks cover repeated duplicate and remove commands.

## Live verification boundary

Earlier live checks confirmed adjustment and pattern double-click resets and zoom increments. The latest full live walkthrough could not be completed: the desktop inspection service returned ScreenCaptureKit capture errors, including for accessibility-only requests. Current source and automated checks therefore do not substitute for a complete pointer/keyboard and visual review.

When desktop inspection is available, finish this smoke pass:

1. Drag rows and use both layer context-menu actions; undo each.
2. Add and drop images, choose a folder with nested images, and use Surprise me.
3. Adjust and reset each slider; exercise presets and Before distortions.
4. Zoom, pan, pinch, and return to Fit at both minimum and larger window sizes.
5. Export through the native file panel and open the resulting PNG.
6. Check light/dark appearance and toolbar grouping; quit without a save prompt.
7. Make 24 trials, select several thumbnails, star/filter favourites, open a trial, and undo. Reopen review and export favourites through the folder panel.
8. Start a new batch, stop it midway, and check that completed trials remain reviewable. Check the review sheet at the minimum window size.

See [Development](DEVELOPMENT.md) for repeatable automated checks.

## Approved native layout

Option 5 is installed in the main app. Build, ad hoc signature verification, and the standard rendering/session checks passed. The experimental app was closed and archived locally with its sources and screenshots. Live inspector collapse/recovery verification is pending while the desktop capture service returns ScreenCaptureKit errors.
