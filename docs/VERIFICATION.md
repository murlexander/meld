# Verification

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
