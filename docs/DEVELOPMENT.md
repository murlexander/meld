# Meld development

A small native Mac playground for abstract colour studies and painting inspiration.

## Try it

Open `Meld.app`. Each session starts with source selection; there is no sample artwork or manual workspace on launch.

1. Choose a folder of photographs or textures. The previous folder is offered without scanning at startup. Pick **Square**, **Portrait**, or **Landscape**.
2. **Generate 36 previews** (⌘R). The main window becomes a grid. Click any preview to refine it; use stars to mark picks and the **Picks** toggle to filter them.
3. Refinement opens a larger, zoomable image with four controls: **Distortion**, **Pattern amount**, **Colour**, and **Contrast**. Distortion and pattern amount scale the generated recipe; colour and contrast adjust its output. Double-click a slider to reset it to its generated default.
4. **Previews** returns to the grid and commits the edits to that image. Reopening it restores those edits. **Reset preview** restores the generated image and is undoable. The comparison toolbar toggle shows the generated original without discarding adjustments.
5. **Export picks** writes adjusted PNGs at 2400 pixels on the longest side, plus a contact sheet rendered from those exports. Each export gets a new subfolder. The refinement toolbar also exports one PNG (⌘E).

**More controls** reveals the layer sidebar and detailed Layer/Canvas inspector. Drag layers to reorder them; right-click to duplicate or remove them. Add images (⌘I) or patterns, expand Placement for crop/rotation/position/mirrored tiling, or adjust individual distortions. **Simple controls** hides that workspace again.

The floating glass **Fit · zoom · %** capsule, scroll/pinch panning, and full-resolution magnified preview remain available in refinement. At 100%, one export pixel maps to one physical display pixel. The toolbar can hide or restore the inspector.

Undo/redo stays within the currently opened preview. Navigation commits edits and starts a fresh adjustment history when another preview opens, preventing undo from applying one image's layers to another. Stars and refinements are independent.

**Choose material** returns to source selection and cancels ongoing generation. Existing previews stay until the first result of a new set succeeds. **New 36 previews** replaces the set; export picks first. Stopping generation keeps completed previews. Stopping export keeps completed PNGs and their contact sheet.

Meld is a one-session image playground. Export the images you want to keep; the canvas is not saved between launches, and closing the app has no save prompt. Source-folder preferences are still remembered. Older `.meld` files are left untouched but no longer opened by this app.

Everything runs locally. No accounts or network services.

This draft imports images supported by macOS Image I/O, including PNG, JPEG, TIFF, HEIC, GIF, and BMP. Animated images use a single frame. Image layers fill the canvas initially; use Scale and Placement to adjust the crop. Imported sources are limited to 3200 pixels on their longest side. The draft has no brush painting, layer masks, or selection tools.

RAW files (such as NEF, ARW, CR2/CR3, RAF, RW2, ORF, and DNG) are candidates for folder mixing and can also be added directly. Meld uses Apple's [native RAW filter](https://developer.apple.com/documentation/coreimage/cirawfilter/init(imageurl:)) with a reduced working size. If development fails, it tries the embedded camera preview. Camera support depends on macOS; extensions alone don't guarantee a file will open. Unreadable files are skipped while finding usable material. Batch generation samples up to 64 candidates to find usable material. If none open, the existing experiment is preserved.

Folder scans only collect file locations; selected images are decoded in the background. Hidden files, package contents, and symbolic links are skipped. Source files are never written to. Hover over an image layer to see its source path. Decoded working images stay in memory for the current session.

Each batch samples up to 12 usable sources from at most 64 candidates, decoding each once at a maximum of 2400 pixels. Trials share those embedded working copies and keep 480-pixel thumbnails; selecting one renders a 1000-pixel refinement image. Every set of six explores all six recipe families. Recipes use deterministic seeded randomness and source-derived palettes; seeds are internal, with no extra settings in the interface. Cancellation is checked during folder traversal, between decodes, and between renders. Late callbacks cannot restore a cancelled batch. Export uses a separate background queue and a unique destination subfolder; existing images are never overwritten by batch export. Trials and favourites are held only for the session.

## Build

Apple Silicon Mac and macOS 14+ to run. Build with Apple command-line developer tools containing a macOS 26+ SDK (older OS versions use native fallbacks):

```sh
zsh build.sh
open Meld.app
```

The app uses SwiftUI, AppKit, and Core Image. It is signed locally with an ad hoc signature.

From the repository root, run the rendering and session checks from a normal Mac terminal (Core Image needs access to the graphics system):

```sh
./Meld.app/Contents/MacOS/Meld --self-test /private/tmp/meld-checks
```

The checks cover native slider resets, zoom geometry and preview resolution, layer commands, patterns, blending, every distortion, comparison, visibility, opacity, placement, canvas shapes, undo/redo, new-canvas undo, drag reordering and its undo/redo, legacy-project rejection, PNG export, recursive folder scanning, source preservation, corrupt files, fresh random selection, background-edit protection, image orientation, and bounded decoding. Workflow checks cover 36 distinct previews, balanced styles, source-first startup, refinement scaling and undo, per-image edit retention, reset and original comparison, picks, adjusted full-size PNGs and contact sheets, cancellation, source disconnection, and preserving previous previews when a folder fails. The optional RAW check also generates 36 previews from one real NEF.

To also check a real RAW image without modifying it:

```sh
MELD_RAW_FIXTURE=/path/to/photo.NEF ./Meld.app/Contents/MacOS/Meld --self-test /private/tmp/meld-checks
```

RAW validation during development used the [rawpy Nikon NEF fixture](https://github.com/letmaik/rawpy/blob/main/test/iss030e122639.NEF), downloaded into a temporary folder only. No sample photography is bundled with the app.

## Interface direction

The main workspace follows source → previews → refinement. Source selection uses a quiet central folder chooser and one prominent generation action. The preview grid owns the full window, with source selection, picks, generation, and export in its header. Refinement preserves the native toolbar, teal accent, right inspector, and floating glass zoom; the layer sidebar is hidden until More controls is requested. Glass buttons have native bordered fallbacks before macOS 26. The minimum window remains 1050 × 700 points.

For UI checks without restoring or changing the saved source preference, launch the executable with `--ui-test`. Add `--ui-test-source /path/to/test/folder` to select a fixture folder without scanning it at startup. All `--self-test` studios likewise use `Studio(restoreSource: false)`.
