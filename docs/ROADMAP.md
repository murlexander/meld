# Meld roadmap

Meld turns a folder of photographs and textures into many abstract possibilities, then helps narrow them to a few painting references. The core loop is **generate → cull → vary → refine → export**. Each direction below should make that loop faster or its results more useful to a painter.

## 0.6 — October 2026

- Picks survive new sets; preview numbers are unique for the session.
- Variations: 12 relatives of any preview, including its adjustments, without decoding sources again.
- Photos-style grid with keyboard culling (arrows, Return, F/D, V) and previous/next in refinement.
- Values and Notan views, palette swatches with hex copy, palettes on contact sheets.
- Copy Image and drag-out at 2400 pixels.
- Faster generation and export through parallel decoding, rendering and PNG encoding.

## Next

1. **Larger exports.** Offer 4800 pixels or a print size. Working copies stop at 2400 pixels, so export would decode the sources again at the larger size.
2. **Thumbnail size.** A grid zoom (⌘+ / ⌘−) as in Photos and Louppe.
3. **Variation focus.** Let a variation row vary one thing: composition, colour, or pattern.
4. **Recipe card.** Export a small text or JSON file beside each PNG with its sources, style and settings, so a pick can be rendered again later.
5. **New styles.** Halftone, gradient map, slit-scan and mosaic families, each tested for distinct output like the existing six.

## Decisions for Alex

- **Session recovery.** Meld is deliberately export-only, with no save prompt. A quiet automatic recovery of the last session (no documents, no prompt) would remove the main remaining way to lose picks. Worth doing?
- **Louppe bridge.** Use Louppe's Yes items as Meld material, and send Meld exports back into the Louppe archive. This is the "broader archive" direction in the README; it needs a shared file convention before code.
- **Distribution.** A signed and notarised build would let others try Meld. That needs a Developer ID and a licence choice.

## Not planned

Brush painting, masks and selection tools: Meld generates references; painting happens elsewhere.
