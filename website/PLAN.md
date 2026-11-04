# Landing page preview

- LP1 — Done: Build a multilingual landing page using DESIGN.md and the approved copy, with English as the default and Simplified Chinese as an additional language. Acceptance: sections render responsively, keyboard-accessible demo controls work, migration scope is accurate, and acquisition links have real destinations.
- Scope: the landing page and, from LP7 onward, the approved brand artwork shared with the native app icon picker. Shared specification documentation remains unchanged.
- Product windows use illustrative content, not screenshots or measurements of the shipping app.
- LP2 — Done: Define the design system in English. DESIGN.md specifies visual tokens, typography, layout, components, responsive behavior, and localization.
- LP4 — Done: Bind `open-arc.trentaml.com` as a Cloudflare custom domain. HTTPS requests to both language routes return HTTP 200 and match the deployed build.
- LP3 — Done: Deploy an isolated Cloudflare preview and verify the live English and Chinese routes, assets, headers, and 404 behavior.
- LP5 — Done: Replace decorative star glyphs with a rounded six-petal SVG bloom and outbound link arrows with consistent rounded-stroke SVGs. Preserve idea-space switching and accessible control names. Static checks and browser review passed.
- LP6 — Done: The user selected the first-round B (Folded arc) concept for production.
- LP7 — Done: Produced a shared vector definition of B, six material treatments, macOS ICNS assets, and a web mark. Replaced the landing logo and native settings icon artwork while retaining persisted choice identifiers. Validated rendering, selection persistence, bundle assets, native tests, and the deployed landing page.

## Validation — November 4, 2026

- Static build and checks passed: translation key parity, dynamic labels, unique IDs, internal anchors, local assets, and acquisition links.
- Browser checks passed on desktop and at 390 CSS pixels: language switching, space selection, theme selection, split view, migration dialog with Escape dismissal, FAQ expansion, and mobile navigation with Escape dismissal.
- Fixed a misbound privacy heading translation and increased demo control hit areas during review.
- Cloudflare dry run and deployment succeeded. Both language routes, JavaScript, CSS, and the app icon return HTTP 200. A missing route returns HTTP 404. Preview security and no-index headers are present. Live HTML and CSS match the local build.
- Live browser verification confirmed that the deployed Chinese space switcher runs under the production content security policy.
- Repository verification: `swift build && swift test` passed; 2,087 native tests executed, 6 skipped, 0 failures. No native application source was changed.

## Preview

- English: https://open-arc.trentaml.com/
- Simplified Chinese: https://open-arc.trentaml.com/zh/
- Cloudflare deployment version: `83cc22b6-fe70-4695-8f3b-46a984f690da`.
- Acquisition buttons link to the public repository until a downloadable release exists.

## Brand rollout validation — November 4, 2026

- `swift build` and `swift test` passed with no compiler warnings: 2,089 tests, 6 skipped, 0 failures. Added coverage for legacy stored identifiers, transparent icon margins, output dimensions and invalid render sizes. Existing selection/relaunch tests pass.
- Exported six 1024 px PNGs and six complete ICNS families. The default bundle icon and web assets use the same paths and renderer as the native picker.
- Built and signed an isolated development app at `build/branding-preview/Open Arc Dev branding.app`. Visually checked all six rows, selected Neon, verified its CURRENT ICON state, and restored Original.
- Website build and static checks passed. English and Chinese HTML, SVG mark and PNG icon all return HTTP 200 and match local artifacts byte for byte. Reviewed the live Chinese landing page in Chrome.
- Visual evidence: `branding/icon-collection.png`, `branding/previews/settings.png`, and `branding/previews/landing.png`.
