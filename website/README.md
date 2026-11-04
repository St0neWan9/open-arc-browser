# Open Arc landing page

A standalone, bilingual static site. English is served at `/` and Simplified Chinese at `/zh/`. Design decisions and reusable visual tokens are defined in [DESIGN.md](DESIGN.md).

Preview: [English](https://open-arc-landing-preview.cmux-remote-relay.workers.dev/) · [Simplified Chinese](https://open-arc-landing-preview.cmux-remote-relay.workers.dev/zh/).

## Local development

Requires Node.js 22 or later. The build has no package dependencies.

```sh
cd website
npm run dev
```

Open `http://127.0.0.1:4180/`. After editing source files, run `npm run build` and refresh. The development server serves generated files from `dist/`.

```sh
npm run build
npm run check
```

## Source files

- `template.html`: shared page structure.
- `locales/en.json` and `locales/zh-CN.json`: matching dictionaries for page copy and interactive labels.
- `style.css`: layout, components, responsive rules, and reduced-motion support.
- `script.js`: illustrative space selection, themes, split view, migration dialog, mobile navigation, and language preference.
- `scripts/`: dependency-free build, static checks, and local server.
- `wrangler.jsonc`: Cloudflare static asset deployment configuration.

Language selection is stored locally in the visitor's browser. A saved Chinese preference redirects the English root to `/zh/`; the English language link explicitly resets that preference. No analytics, forms, or third-party scripts are included.

## Content and preview scope

Browser windows are interactive illustrations, not screenshots of the shipping app. Product copy distinguishes local storage from optional personal iCloud synchronization, and the migration dialog explains which Arc data can be imported. It does not promise migration of every preference, extension, or signed-in session.

The public repository has no downloadable release as of this preview. Acquisition buttons say “Get Open Arc” and link to the repository. Replace their destinations with a verified release URL when a public build becomes available.

This test deployment includes `noindex, nofollow` metadata and response headers, and disallows crawlers in `robots.txt`. Before a public launch, review those settings and add the final canonical URLs, sitemap, and social sharing image.

## Cloudflare deployment

With an authenticated Wrangler installation:

```sh
npm run build
npm run check
wrangler deploy --dry-run
wrangler deploy
```

Only `dist/` is deployed. The worker serves static assets and has no storage bindings or application backend. The preview uses a separate `open-arc-landing-preview` worker and does not change existing sites or custom domains.
