# Meld

Meld is a small native macOS playground that turns a folder of photographs and textures into unexpected patterns and painting references. Generate a set, refine the promising images, and export your picks as PNGs.

This is an experimental side development adjacent to [Louppe](https://github.com/murlexander/louppe-media-culler). For now, Meld is a standalone, one-session image creator: there are no saved projects or continuing workspaces.

Future updates may bring Meld and Louppe together within a broader archive for artwork and creative material. That is a later direction, not part of the current app.

## Current workflow

1. Choose a source folder and a square, portrait, or landscape format.
2. **Generate 36 previews** (⌘R). Each set explores six styles, with RAW files and subfolders included.
3. Click a promising preview to refine it. Adjust distortion, pattern amount, colour, and contrast; star it as a pick.
4. Return to **Previews**. Your edits stay with each image. **Export picks** writes 2400-pixel PNGs and a contact sheet of the adjusted results.

The previews are the main workspace. Layer and detailed canvas controls are available under **More controls** when needed. Compare with the generated original or reset a preview; undo/redo applies to its adjustments.

Export your picks before generating a new set or closing the app. Sessions are temporary; the last source folder is remembered without scanning at startup.

The generator explores Flow, Vortex, Blocks, Collage, Weave, and mirrored Tiles, using colours sampled from the source images. RAW files use macOS's decoder, with embedded previews as a fallback when available.

The interface uses native macOS controls, Liquid Glass on macOS 26+, and a restrained teal accent. Image processing runs locally; original source files are not modified.

## Build

Requires an Apple Silicon Mac running macOS 14 or later. Building requires Apple command-line developer tools with a macOS 26 or newer SDK.

```sh
zsh build.sh
open Meld.app
```

There is no packaged release yet. Build, test, and format details are in [Development](docs/DEVELOPMENT.md).

No open-source license is included.
