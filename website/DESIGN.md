# Open Arc — Landing Page Design System

Status: **Implemented in the landing page preview**
Scope: Open Arc product website and landing page

## 1. Visual character

Warm, personal, spacious, and quietly playful. The visual system combines soft color fields, expressive serif headings, tactile paper layers, and prominent desktop product windows.

- Warm paper forms the page foundation.
- Sky blue, lavender, sage, peach, and butter yellow distinguish sections and browsing spaces.
- Large product windows anchor the composition.
- Paper layers add texture and depth around the product.
- Typography and whitespace establish hierarchy before borders or cards.
- Short, readable copy sits close to the visual that explains it.

## 2. Identity and visual principles

### Brand

- Use the existing Open Arc application icon with a plain `Open Arc` wordmark.
- The wordmark uses the UI sans-serif family at weight 700–750 with slightly tightened Latin tracking.
- Minimum icon size: 28 px in navigation and 24 px in the footer.
- Leave at least half the icon width between the brand lockup and unrelated elements.
- Do not add a registered-trademark symbol or another product's logo to the brand lockup.

### Composition

- Place the hero inside a large rounded color field.
- Use a compact pale navigation surface within the hero.
- Make the browser window the most detailed object in a product section.
- Alternate centered, split-column, and wide demonstration layouts.
- Give each section one clear focal point.
- Limit paper decorations to the edges of the composition; keep text and controls unobstructed.

### Restraint

- Avoid neon glows, ornamental 3D objects, and repeated generic card grids.
- Limit strong gradients to broad atmospheric fields.
- Keep decorative motifs small and purposeful.
- Use the six-petal rounded bloom in `assets/icons.svg` for decorative floral accents and idea-space markers. Preserve the central cutout and the same silhouette at every size.
- Directional link icons use a 24 px SVG view box with a 1.6 px stroke, rounded caps, and rounded joins. Render them at 18 px in primary buttons and about 1.1 em next to text.
- Use vector icons for floral motifs and outbound arrows rather than font glyphs. Decorative SVGs are hidden from assistive technology; the surrounding control supplies the accessible name.
- Use one source of visual depth per layer: a soft shadow, an overlap, or a color contrast.

## 3. Color system

The base is warm paper with dark olive-charcoal text. Broad color fields remain soft enough for the product window to be the most detailed object on the page.

| Token | Value | Role |
| --- | --- | --- |
| `color.canvas` | `#F8F7F3` | Main page background |
| `color.surface` | `#FFFEF8` | Paper layers, dialogs, elevated content |
| `color.ink` | `#20211E` | Headings and primary text |
| `color.body` | `#62665C` | Body copy on light surfaces |
| `color.muted` | `#73776D` | Secondary labels; verify contrast on each surface |
| `color.line` | `#DCDDD4` | Subtle separators and decorative borders |
| `color.action` | `#23241F` | Primary buttons |
| `color.action-hover` | `#424338` | Hovered primary buttons |
| `color.action-text` | `#FFFDF6` | Primary button text |
| `color.sky` | `#C6E2EC` | Hero field |
| `color.sky-soft` | `#D8E8DF` | Gentle secondary tone inside the hero |
| `color.lavender` | `#D9D2E9` | Browser shell and inspiration space |
| `color.lavender-paper` | `#C5BCE8` | Decorative purple paper |
| `color.sage` | `#E8EDDF` | Privacy section and life space |
| `color.sage-strong` | `#7D8969` | Decorative leaves, flowers, and diagrams |
| `color.peach` | `#E7CEBF` | Split-view theme |
| `color.butter` | `#F5E7A5` | Notes and small paper accents |
| `color.rose` | `#E6BCC7` | Secondary collage accents |
| `color.focus` | `#5A65C9` | Keyboard focus indicator |

Rules:

- Give each section one dominant surface color and at most two small accent colors.
- Keep most reading sections on the canvas background. Reserve full fields for the hero, split-view demonstration, privacy, and closing call to action.
- Treat these as website tokens. They are not measured native-browser design tokens.
- Meet WCAG AA text contrast: 4.5:1 for normal text and 3:1 for large text. Pastel color and texture must never reduce essential text contrast.
- Use stronger borders when required to identify a control. Decorative separators may remain quiet.

## 4. Typography

### Font families

| Role | Stack | Use |
| --- | --- | --- |
| Simplified Chinese display | `"Songti SC", "STSong", "Noto Serif CJK SC", serif` | Hero and section headlines |
| UI and body | `-apple-system, BlinkMacSystemFont, "PingFang SC", "Microsoft YaHei", sans-serif` | Navigation, paragraphs, controls, product UI |
| English display | `Georgia, "Times New Roman", serif` | Hero, section headlines, and occasional italic accents |
| Keyboard shortcuts | `ui-monospace, SFMono-Regular, Menlo, monospace` | Keyboard hints only |

The first local draft can use installed fonts. Before public release, verify the Chinese serif rendering on macOS, Windows, Android, and iOS. If a consistent webfont is needed, select a properly licensed and subsetted CJK font; do not assume that a system-only font will exist everywhere.

### Type scale

| Role | Desktop | Mobile | Weight / line height |
| --- | --- | --- | --- |
| Hero headline | 88–96 px | 48–54 px | 500 / 1.18–1.25 |
| Major section heading | 44–50 px | 32–36 px | 500 / 1.35–1.45 |
| Feature heading | 24–28 px | 23–25 px | 500 / 1.45 |
| Body paragraph | 15–17 px | 14–16 px | 400 / 1.8–1.9 |
| Navigation and button | 13–15 px | 13–15 px | 500–600 / 1.4 |
| Eyebrow label | 10–11 px | 10 px | 600 / 1.6 |
| Secondary caption | 11–12 px | 11–12 px | 400 / 1.6 |

- Chinese headings use natural tracking, from `0` to approximately `-0.02em`; avoid overly tight character spacing.
- English hero line break: `The Arc you know.` / `Continued.` Localized headlines use their own natural line breaks.
- Use serif headings to create character and sans-serif copy to maintain readability.
- Limit uppercase English tracking to micro-labels (`0.12–0.18em`).
- Small text inside an illustrative product window is visual context, not the only place a feature is explained.
- Never shrink essential page copy to make a layout fit.

## 5. Layout and spacing

### Page geometry

| Token | Desktop | Mobile |
| --- | --- | --- |
| Outer colored-section gutter | 16 px | 8 px |
| Reading container maximum | 1120 px | Available width minus 48 px |
| Hero / wide demonstration maximum | 1200–1260 px | Available width minus 24–32 px |
| Navigation maximum | 1180 px | Available width minus 44 px |
| Section vertical spacing | 96–120 px | 56–72 px |
| Two-column gap | 64–100 px | Stacked with 28–40 px gap |
| Body paragraph measure | 45–65 Latin characters or 26–30 CJK characters | Available column width |

Spacing scale: `4, 8, 12, 16, 24, 32, 48, 64, 96, 120` px.

- Use a centered content system with deliberate asymmetry inside sections.
- Keep headings, supporting copy, and product demonstrations visually connected.
- Do not repeat the same text-left/image-right arrangement through the whole page.
- Use whitespace as a section boundary. Numbered editorial labels are optional; no ornamental dividers between every block.
- The first viewport should show the headline, download action, and a meaningful portion of the browser window.

### Breakpoints

- **Above 1200 px:** full desktop composition.
- **900–1200 px:** reduce horizontal gaps and side decorations, preserve readable text sizes.
- **640–900 px:** simplify collage layers, allow text-heavy two-column sections to stack.
- **Below 640 px:** one column, compact navigation menu, larger tap targets, stacked features.

Use content-driven adjustments within these ranges; do not depend on a single ideal screenshot width.

## 6. Shape, texture, and depth

### Radius

| Element | Radius |
| --- | --- |
| Large colored section | 24–28 px desktop; 16–18 px mobile |
| Floating navigation | 18–22 px |
| Main product window | 14–18 px |
| Primary button | 10–12 px |
| Feature demonstration panel | 8–12 px |
| Paper note or printed sheet | 2–4 px |
| Modal | 16–20 px |

### Shadows

```css
--shadow-paper: 2px 8px 20px rgb(59 66 47 / 8%);
--shadow-panel: 0 12px 30px rgb(46 53 45 / 10%);
--shadow-product: 0 35px 65px -25px rgb(56 75 76 / 35%),
                  0 3px 6px rgb(42 47 41 / 10%);
```

- Product windows have the strongest depth. Paper and navigation remain lighter.
- Use one very subtle grain overlay on the hero only. It must not affect text legibility or animate.
- Paper rotations range from `-8deg` to `8deg`; use larger rotations sparingly for a small sticker.
- Torn edges belong to one or two large paper layers, never to interactive controls.
- Decorative papers are placed behind the product, with sufficient space to avoid cropping or covering controls.
- Make decoration non-interactive and hidden from assistive technology.

## 7. Component rules

### Navigation

- Existing app icon plus a plain `Open Arc` wordmark.
- Desktop links: Features / Move from Arc / Your data / GitHub.
- One primary download action.
- Pale translucent background; blur is progressive enhancement, with a readable solid fallback.
- Position within the hero; do not introduce a permanent floating overlay that obscures content while scrolling.
- Mobile menu exposes the same destinations. Announce expanded state, support Escape, and close after navigation.

### Buttons and links

- Primary: dark surface, light text, optional download icon, small directional arrow.
- Secondary: underlined text with generous pointer and touch area.
- Download links lead to a real release destination. If a release is unavailable, name the destination accurately rather than showing a nonfunctional download control.
- Distinguish external navigation from local demonstration actions.
- Interactive targets should be at least 44 × 44 px on touch screens, including theme and space controls.

### Application demonstrations

- Use the existing Open Arc icon and independently authored sample content.
- Preserve the recognizable browser structure: sidebar, Favorites, pinned folders, Today, Space switcher, and page area.
- Show calm, plausible browsing contexts such as a project, a reading list, or weekend planning.
- Caption HTML-built demonstrations as **Interactive illustration**. They are not evidence of pixel-perfect native UI.
- Replace demonstrations with approved app captures where exact product appearance matters before public release.
- Do not expose personal tabs, account names, history, or files in captured assets.
- Mobile should use a purposeful crop or a simplified composition. Keep any interactive controls comfortably tappable.
- Essential meaning must also appear in normal page text outside the demonstration.

### Feature panels

- Reserve a two-column card arrangement for Peek, Little Arc, Command Bar, and Easel.
- Each panel contains one specific visual, the feature name, a short benefit headline, and a short explanation.
- Vary the internal illustration while keeping panel geometry consistent.
- Avoid making decorative mock controls look like functional website controls.

### Migration details dialog

- Open from the migration text action.
- List the confirmed migration categories and meaningful exclusions.
- Use native dialog focus handling, a named close button, Escape dismissal, and focus restoration.
- Keep content scrollable within the viewport on small screens.
- Never imply that clicking the website demo imports actual browser data.

### FAQ

- Quiet disclosure rows separated by fine lines.
- Questions remain full sentences with visible expand/collapse state.
- Answers use body typography and explain migration scope, account requirements, synchronization scope, and feature gaps.
- Use semantic `details` / `summary` or an equivalent accessible implementation.

## 8. Page composition

| Section | Message | Composition | Interaction |
| --- | --- | --- | --- |
| Hero | The Arc you know. Continued. | Sky field, centered serif headline, restrained paper collage, large lavender browser window | Three sample Spaces change the window theme and sample content |
| Migration | You already made it yours. | Text on one side; two overlapping sidebar sheets retaining the same structure on the other | Open the supported-import details |
| Spaces and Profiles | A space for every side of you. | Centered heading followed by three tactile compositions for work, life, and inspiration | Optional link back to the hero demonstration; no redundant controls |
| Sidebar and archive | Keep your essentials. Travel light. | An organized visual list opposite the explanation | Static, clearly illustrative hierarchy |
| Split View and Themes | Browse your way. | Wide product demonstration on a warm neutral field | Switch peach/lavender/sage themes; toggle a two-page illustration |
| Familiar details | The little things you would miss. | Four specific product panels | Static illustrative previews for the first version |
| Privacy and sync | Your browser. Your data. | Sage field, explanatory copy, two Macs connected through a personal iCloud diagram | Read-only diagram |
| Open source | A browser with room to keep growing. | A restrained paper/code motif and a clear source-code invitation | GitHub link |
| FAQ | A few things to know. | Short heading and expandable questions | Disclosure controls |
| Closing | Bring your spaces. Keep browsing. | Soft sky/lavender field, generous space, single primary action | Download link |

Each section uses a distinct composition while retaining the same typography, spacing, surface, and control rules.

## 9. Motion and interaction

| Interaction | Duration | Behavior |
| --- | --- | --- |
| Button hover | 150–180 ms | Small surface change; at most 2 px vertical movement |
| Space or theme change | 200–300 ms | Update relevant content immediately; softly transition shell color |
| Paper hover | 180–240 ms | Optional lift of at most 4 px; no continuous floating |
| Menu / dialog | 160–220 ms | Simple opacity change or native appearance |
| Anchor navigation | Browser smooth scroll | Respect reduced-motion preference |

- No scroll hijacking, cursor followers, parallax-bound text, loading spectacle, or automatic carousels.
- Demonstrations work without animation and remain understandable in a static screenshot.
- Disable optional animation and smooth scrolling under `prefers-reduced-motion: reduce`.
- Never depend on hover to reveal essential information.
- Do not add global keyboard shortcuts that override normal browser behavior merely because a mockup shows a shortcut.

## 10. Assets and rendering

- Use semantic document structure, real links, native buttons, and native disclosures.
- The existing `app/Bundle/AppIcon.icns` is the source for the website icon export.
- Paper textures and simple diagrams may use lightweight CSS or original SVG.
- Keep decorative landscapes stylized and original. They illustrate sample page content, not product functionality.
- Avoid remote trackers, unnecessary third-party scripts, and external fonts in the first preview.
- Keep image dimensions explicit to prevent layout shifts.
- Use responsive images for any later product captures; avoid making a large video necessary to understand a section.
- Keep all project documentation, specification examples, and code comments in English. Website copy is localized separately.

## 11. Localization

- English (`en`) is the default website language. Simplified Chinese (`zh-CN`) is the additional launch language.
- Maintain one shared design system and component structure across locales.
- Keep visitor-facing strings in locale dictionaries, including navigation, calls to action, FAQ answers, dialog content, accessibility labels, image descriptions, and interactive demonstration content.
- Use stable semantic translation keys; do not use English sentences as keys or embed translations inside component logic.
- Provide an explicit language selector labeled with language names, not national flags. Preserve the current section when switching languages.
- Set the document language, page title, and description to match the active locale. If locale-specific URLs are used, provide matching canonical and alternate-language metadata.
- Remember an explicit language choice. The default remains English when no choice has been made.
- Use the English display font for Latin headlines and the CJK display stack for Chinese headlines. Adjust tracking and line breaks per locale without changing the visual hierarchy.
- Allow navigation, buttons, cards, and dialogs to grow with translated text. Never truncate essential copy to preserve a fixed height.
- Localize complete phrases and sentences; avoid concatenating translated fragments.
- Keep brand names and established feature names such as Open Arc, Spaces, Peek, and Little Arc consistent across locales.
- Verify both languages at every supported breakpoint, including keyboard navigation and assistive labels.

## 12. Acceptance criteria for the first visual version

### Visual

- Use soft color fields, expressive serif headlines, tactile paper, and prominent product windows consistently.
- Use the Open Arc identity and approved assets consistently.
- The first viewport establishes the product, Arc continuity, and the next action.
- Migration, Spaces, and split browsing receive the largest product demonstrations.
- Secondary sections vary their composition without becoming visually unrelated.

### Interaction and accessibility

- Verify at 1440 px, 1024 px, 768 px, and 390 px viewport widths, plus a narrow 320 px overflow check.
- No horizontal page overflow, clipped body copy, or overlapped controls.
- Hero Space switches, theme controls, split toggle, migration dialog, mobile menu, FAQ, anchors, and external links work.
- Complete the page using the keyboard; verify visible focus and modal focus return.
- Verify text contrast, 44 px touch targets, meaningful labels, and reduced-motion behavior.
- Check console errors and failed local assets in browser QA.
