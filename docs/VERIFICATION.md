# Verification — 6 October 2026

The current build passes 139 rendering and session checks, including a real Nikon NEF fixture. The fixture and generated output are not bundled or committed.

| Requested behavior | Implementation and verification |
| --- | --- |
| Comfortable native controls and familiar left panel | Layers, source folder, patterns, and Surprise me remain in the sidebar; regular/large native controls and macOS 26 glass styles with older-system fallbacks. |
| Restrained teal accent | Adaptive teal for app actions and zoom; ordinary glass buttons are neutral. Native system selection styling can still follow macOS appearance. |
| Icon-only toolbar, separate undo/redo group | Undo/redo, comparison, and far-right Export are separated with native toolbar spacers on macOS 26. |
| Export only; no saved projects | No Save command, document type, restoration of artwork, or save-on-close prompt. PNG export validated at 2400 pixels on the longest side. |
| Add images in Layers | Button beside the Layers heading; image-import model tested. |
| Right controls always visible | Fixed inspector in the detail layout, without a visibility toggle. |
| Drag layers; remove action strip | Native List reordering; model order and undo/redo tested. Duplicate and Remove remain in the context menu. |
| Always include subfolders | Recursive scanning and mixing from images two folders deep tested; no checkbox. |
| Before distortions in toolbar | Toolbar toggle; renderer comparison validated for effects. |
| Minimal glass zoom below the canvas | Fit, logarithmic slider, percentage, scrolling, and pinch handling. Pixel geometry and full-resolution magnified previews tested. |
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

See [Development](DEVELOPMENT.md) for repeatable automated checks.
