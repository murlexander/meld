# Meld

Meld is a small native macOS playground for creating images that can become starting points for paintings. Combine photographs and patterns, adjust blends and distortions, and export the results as PNGs.

This is an experimental side development adjacent to [Louppe](https://github.com/murlexander/louppe-media-culler). For now, Meld is a standalone, one-session image creator: there are no saved projects or continuing workspaces.

Future updates may bring Meld and Louppe together within a broader archive for artwork and creative material. That is a later direction, not part of the current app.

## Current workflow

- Add photographs from the Layers panel or drop them onto the canvas.
- Drag layers to reorder them; right-click to duplicate or remove a layer.
- Mix a source folder with **Surprise me**. Subfolders are always included.
- Adjust layers and canvas effects in the permanently visible controls panel. Double-click a slider to reset its default.
- Compare before distortions from the toolbar, and use **Fit · zoom · %** below the canvas.
- Export a PNG at 2400 pixels on its longest side. Undo and redo work within the current session.

The interface uses native macOS controls, Liquid Glass on macOS 26+, and a restrained teal accent. Image processing runs locally; original source files are not modified.

## Build

Requires an Apple Silicon Mac running macOS 14 or later. Building requires Apple command-line developer tools with a macOS 26 or newer SDK.

```sh
zsh build.sh
open Meld.app
```

There is no packaged release yet. Build, test, and format details are in [Development](docs/DEVELOPMENT.md).

No open-source license is included.
