# Open Arc identity

The approved identity is a broad folded ribbon with an open triangular counter. Lavender, periwinkle and blue-violet folds form the default mark. The artwork contains no pure black.

## Files

- `open-arc.svg`: scalable transparent brand mark for websites and other layouts.
- `previews/settings.png`: the implemented native picker.
- `previews/landing.png`: the deployed Chinese landing page.
- `icon-collection.png`: overview of the six material treatments, including small-size previews.
- `icons/*.png`: 1024 × 1024 transparent macOS icon canvases.
- `icons/*.icns`: complete macOS icon families, from 16 px through 1024 px.
- `../app/Bundle/AppIcon.icns`: the Original icon used by packaged applications.

| Visible name | File stem | Persisted identifier | Treatment |
| --- | --- | --- | --- |
| Original | original | slate | Matte-satin lavender folds on a softly glazed lilac tile |
| Candy | candy | sunrise | Peach and lilac ribbon, pink tile, raised white edge |
| Neon | neon | night | Luminous pink and violet contours on midnight indigo |
| Fluted Glass | fluted-glass | lagoon | Muted lilac and coral under translucent vertical ribs |
| Paper | paper | paper | Blue, teal and orange sticker on butter-yellow paper |
| Spectrum | spectrum | prism | Fuchsia, amber and violet on deep plum |

Identifiers are retained for compatibility with existing device preferences. All six treatments are available without unlocking. Choosing an icon updates the running app's Dock and app-switcher image and persists the selection. Finder continues to show the signed bundle's Original icon; the bundle is never modified at runtime.

## Material consistency

All variants share the same tile geometry, ribbon proportions, top-left lighting and soft cast shadow. Tile highlights fade with the light direction instead of forming a uniform white outline. Original uses a softly glazed lilac base and restrained fold shading, without white specular strokes on its ribbon. Dark and paper treatments use reduced surface illumination; Candy and Paper retain their sticker silhouettes, Neon retains its luminous contours, and Fluted Glass retains its vertical ribs.

## Regeneration

From the repository root on macOS:

```sh
swift scripts/make-app-icon.swift
```

An optional argument overrides the destination for the default ICNS. The full collection and website assets are always refreshed. The script uses system Swift, CoreGraphics, ImageIO, CoreText and `iconutil`; no third-party installation is required.

The shared source is `app/Sources/OpenArcShell/Appearance/AppIconArtwork.swift`. Its ribbon paths drive both the SVG master and bitmap rendering. Runtime settings previews use the same renderer as the exports. Each ICNS size is rendered directly, with transparent margins and an 824-unit tile on a 1024-unit canvas.

Use the transparent SVG in navigation and wordmark lockups. Use the Original tile for application illustrations and the favicon. Preserve proportions, the triangular opening, and generous clear space. Do not replace the folds with thin strokes except in the Neon material treatment.
