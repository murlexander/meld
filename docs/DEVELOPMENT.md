# Meld development

A small native Mac playground for abstract colour studies and painting inspiration.

## Try it

Open `Meld.app`. It starts with a colour study you can change freely.

- Drop images or textures onto the canvas, or use the **Add images** button beside the Layers heading (⌘I).
- The left panel holds your layers, source folder, pattern buttons, and **Surprise me**. Drag layer rows up or down to change their stacking order; the top row appears above the others. Reordering supports undo/redo. Right-click a layer to duplicate or remove it. Select a layer to blend it or change its pattern. Expand **Placement** for scale, rotation, and position.
- In the **Canvas** controls, try Wave, Twist, Bulge, or Pixelate. Click or drag on the image to move the distortion centre.
- Try **Flow**, **Vortex**, **Blocks**, or **Surprise me**. Undo (⌘Z) lets you explore freely.
- Under **Source material**, choose a folder of images or textures. **Surprise me** now takes 2–3 random images from it (or one if that's all there is), combines them with a pattern, and distorts the composition. The next click prefers different source files when available. Undo restores the previous experiment.
- Subfolders are always included. Meld remembers your folder between launches without scanning it at startup, and checks it on each surprise, so newly added files can be used. Choose **Disconnect folder** from the source options menu to return to experimenting with the current layers.
- The **Before distortions** toolbar toggle shows the layered image without the canvas effects.
- The small glass control beneath the canvas provides **Fit**, a logarithmic zoom slider, and a percentage. Scroll to pan when enlarged. Double-click the zoom slider to return to Fit. At 100%, one export pixel maps to one physical display pixel.
- Double-click any layer or canvas slider to reset it to its default.
- **Export PNG** (⌘E) writes a 2400-pixel image on the longest side.

Meld is a one-session image playground. Export the images you want to keep; the canvas is not saved between launches, and closing the app has no save prompt. Source-folder preferences are still remembered. Older `.meld` files are left untouched but no longer opened by this app.

Everything runs locally. No accounts or network services.

This draft imports images supported by macOS Image I/O, including PNG, JPEG, TIFF, HEIC, GIF, and BMP. Animated images use a single frame. Image layers fill the canvas initially; use Scale and Placement to adjust the crop. Imported sources are limited to 3200 pixels on their longest side. The draft has no brush painting, layer masks, or selection tools.

RAW files (such as NEF, ARW, CR2/CR3, RAF, RW2, ORF, and DNG) are candidates for folder mixing and can also be added directly. Meld uses Apple's [native RAW filter](https://developer.apple.com/documentation/coreimage/cirawfilter/init(imageurl:)) with a reduced working size. If development fails, it tries the embedded camera preview. Camera support depends on macOS; extensions alone don't guarantee a file will open. Unreadable files are skipped while finding usable material. Up to 32 candidates are tried for each surprise. If none open, the existing experiment is preserved.

Folder scans only collect file locations; selected images are decoded in the background. Hidden files, package contents, and symbolic links are skipped. Source files are never written to. Hover over an image layer to see its source path. Decoded working images stay in memory for the current session.

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

The checks cover native slider resets, zoom geometry and preview resolution, layer commands, patterns, blending, every distortion, comparison, visibility, opacity, placement, canvas shapes, undo/redo, new-canvas undo, drag reordering and its undo/redo, legacy-project rejection, PNG export, recursive folder scanning, source preservation, corrupt files, fresh random selection, background-edit protection, image orientation, and bounded decoding.

To also check a real RAW image without modifying it:

```sh
MELD_RAW_FIXTURE=/path/to/photo.NEF ./Meld.app/Contents/MacOS/Meld --self-test /private/tmp/meld-checks
```

RAW validation during development used the [rawpy Nikon NEF fixture](https://github.com/letmaik/rawpy/blob/main/test/iss030e122639.NEF), downloaded into a temporary folder only. No sample photography is bundled with the app.

## Interface direction

The left sidebar keeps layers, source material, patterns, and Surprise me within reach. Layer and Canvas controls share the permanently visible right panel. Native macOS toolbars and larger Liquid Glass buttons keep common actions readable; a restrained teal accent adapts to light and dark appearance. The icon-only toolbar groups undo/redo, a Before distortions toggle, and the prominent Export button at the far right. Add images sits beside the Layers heading on the left. Glass buttons use standard bordered fallbacks before macOS 26. Placement remains expandable, while the canvas effects and colour controls are directly visible. The minimum window is 1050 × 700 points.

For UI checks without restoring or changing the saved source preference, launch the executable with `--ui-test`. All `--self-test` studios likewise use `Studio(restoreSource: false)`.
