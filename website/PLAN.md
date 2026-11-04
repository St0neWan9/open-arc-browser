# Landing page preview

- LP1 — Done: Build a multilingual landing page using DESIGN.md and the approved copy, with English as the default and Simplified Chinese as an additional language. Acceptance: sections render responsively, keyboard-accessible demo controls work, migration scope is accurate, and acquisition links have real destinations.
- Scope: standalone static website; no changes to the native browser or shared documentation.
- Product windows use illustrative content, not screenshots or measurements of the shipping app.
- LP2 — Done: Define the design system in English. DESIGN.md specifies visual tokens, typography, layout, components, responsive behavior, and localization.
- LP4 — Done: Bind `open-arc.trentaml.com` as a Cloudflare custom domain. HTTPS requests to both language routes return HTTP 200 and match the deployed build.
- LP3 — Done: Deploy an isolated Cloudflare preview and verify the live English and Chinese routes, assets, headers, and 404 behavior.
- LP5 — Done: Replace decorative star glyphs with a rounded six-petal SVG bloom and outbound link arrows with consistent rounded-stroke SVGs. Preserve idea-space switching and accessible control names. Static checks and browser review passed.
- LP6 — Concepts delivered: Create four Open Arc logo directions for user selection. Original previews and generation prompts are saved in `design/logo-exploration/`. Production logo selection is pending.

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
- Cloudflare deployment version: `4ba8b7f6-5687-47fe-8a51-b7ce3ef7a748`.
- Acquisition buttons link to the public repository until a downloadable release exists.
