# Meld

Meld is a small native macOS app that turns a folder of photographs and textures into abstract patterns and painting references. Generate a set, refine the promising images, and export your picks as PNGs.

Meld is an experimental side project next to [Louppe](https://github.com/murlexander/louppe-media-culler). It is a standalone app that works in one session at a time, with no saved projects or workspaces.

Future updates may bring Meld and Louppe together in a broader archive for artwork and creative material. The current app does not do this.

## Current workflow

1. Choose a source folder and a square, portrait, or landscape format.
2. **Generate 36 previews** (⌘R). Each set explores five styles, with RAW files and subfolders included.
3. Browse like Photos: click to select, double-click or Return to refine, arrow keys to move. **F** picks and **D** unpicks, as in Louppe.
4. **Variations** (V or ⌥⌘R) adds a row of 12 relatives of the selected preview, from close to bold, using images already in memory.
5. Refine a preview: adjust distortion, pattern amount, colour, and contrast. More controls adds masks, mirror, colour treatment, blur and grain. Step through previews with ⌘[ and ⌘]. Esc returns to the grid. Your edits stay with each image.
6. Check composition with the **Values** and **Notan** views (⌘2, ⌘3), and copy the preview's palette as hex values.
7. **Export picks** writes 2400-pixel PNGs and a contact sheet with palettes. Copy Image (⇧⌘C) or drag a preview into another app for a single full-size PNG.

A new set keeps your picks in their own rows and replaces the rest. Sessions are still temporary: export picks before closing the app. The last source folder is remembered without scanning at startup.

The previews are the main workspace. Layer and detailed canvas controls are available under **More controls** when needed. Compare with the generated original or reset a preview. Undo and redo apply to its adjustments.

Meld generates abstract art ideas for painting. It has five styles: Flow, Vortex, Blocks, Detail, and mirrored Tiles. Every photo is placed full-bleed as a rotated and often strongly zoomed crop that never shows its edges. Colours are sampled from the source images. Each preview adds a few independent stages that simplify it into colour and shape: mirror symmetry or stretch, double exposures and soft fades between photos, a gradient map, palette swap or value bands, and motion or zoom blur. A set mixes quiet and bold previews and never repeats a combination. Meld starts showing previews while it gathers the remaining material. RAW files use the macOS decoder. Meld works on smaller previews and keeps the developed images for export. Embedded camera previews are a fallback when native development is unavailable.

The interface uses native macOS controls, Liquid Glass on macOS 26 or later, and a teal accent. Image processing runs locally; original source files are not modified.

Planned work is in the [backlog](docs/BACKLOG.md).

## Build

Requires an Apple Silicon Mac running macOS 14 or later. Building requires Apple command-line developer tools with a macOS 26 or newer SDK.

```sh
zsh build.sh
open Meld.app
```

There is no packaged release yet. Build, test, and format details are in [Development](docs/DEVELOPMENT.md).

No open-source license is included.
