# Meld

Meld is a small native macOS playground that turns a folder of photographs and textures into unexpected patterns and painting references. Generate a set, refine the promising images, and export your picks as PNGs.

This is an experimental side development adjacent to [Louppe](https://github.com/murlexander/louppe-media-culler). For now, Meld is a standalone, one-session image creator: there are no saved projects or continuing workspaces.

Future updates may bring Meld and Louppe together within a broader archive for artwork and creative material. That is a later direction, not part of the current app.

## Current workflow

1. Choose a source folder and a square, portrait, or landscape format.
2. **Generate 36 previews** (⌘R). Each set explores five styles, with RAW files and subfolders included.
3. Browse like Photos: click to select, double-click or Return to refine, arrow keys to move. **F** picks and **D** unpicks, as in Louppe.
4. **Variations** (V or ⌥⌘R) adds a row of 12 relatives of the selected preview, from close to bold, using images already in memory.
5. Refine a preview: adjust distortion, pattern amount, colour, and contrast. Step through previews with ⌘[ and ⌘]; Esc returns to the grid. Your edits stay with each image.
6. Check composition with the **Values** and **Notan** views (⌘2, ⌘3), and copy the preview's palette as hex values.
7. **Export picks** writes 2400-pixel PNGs and a contact sheet with palettes. Copy Image (⇧⌘C) or drag a preview into another app for a single full-size PNG.

A new set keeps your picks in their own rows and replaces the rest. Sessions are still temporary: export picks before closing the app. The last source folder is remembered without scanning at startup.

The previews are the main workspace. Layer and detailed canvas controls are available under **More controls** when needed. Compare with the generated original or reset a preview; undo/redo applies to its adjustments.

The generator explores Flow, Vortex, Blocks, Detail, and mirrored Tiles, placing every photo full-bleed (a turned, often zoomed crop, never showing its edges), using colours sampled from the source images. It starts showing previews while gathering the remaining material. RAW files use macOS's decoder; smaller working previews speed up exploration while developed images are retained for export. Embedded camera previews are a fallback when native development is unavailable.

The interface uses native macOS controls, Liquid Glass on macOS 26+, and a restrained teal accent. Image processing runs locally; original source files are not modified.

Planned work is in the [backlog](docs/BACKLOG.md).

## Build

Requires an Apple Silicon Mac running macOS 14 or later. Building requires Apple command-line developer tools with a macOS 26 or newer SDK.

```sh
zsh build.sh
open Meld.app
```

There is no packaged release yet. Build, test, and format details are in [Development](docs/DEVELOPMENT.md).

No open-source license is included.
