# isthmus.channel

Public site for [Isthmus](https://github.com/synalysis/isthmus) — built with [Elm Land](https://elm.land) and styled like [elm-pebble](https://github.com/synalysis) via [`elm-tailwind-classes`](https://github.com/dillonkearns/elm-tailwind-classes) + Tailwind CSS v4.

## Local development

From the repo root:

```bash
./bin/dev-site
```

Dev server: [http://localhost:4568](http://localhost:4568) (override with `PORT=...`).

Or directly:

```bash
cd isthmus_channel
pnpm install
pnpm dev
```

`pnpm dev` generates the typed Tailwind Elm API, compiles CSS, then runs Elm Land with a CSS watcher.

## Styling

- Theme + custom CSS: `src/styles.css`
- Typed classes in Elm: `import Tailwind as Tw exposing (classes)`
- Pipeline (Elm Land cannot load Vite plugins): `scripts/tailwind.mjs`
  - `elm-tailwind-classes` codegen → `.elm-tailwind/`
  - elm-review class extraction → safelist
  - `@tailwindcss/cli` → `src/generated.css` (imported from `src/interop.js`)

```bash
pnpm gen:tailwind   # one-shot codegen + CSS
pnpm css:watch      # watch CSS only
```

## Production build

```bash
pnpm build
# → ./dist
```

## Render.com

The repo-root `render.yaml` defines a static site service `isthmus-channel`:

| Setting | Value |
|---|---|
| Root directory | `isthmus_channel` |
| Build command | `pnpm install --frozen-lockfile && pnpm run build` |
| Publish path | `isthmus_channel/dist` |
| SPA rewrite | `/*` → `/index.html` |

After the first deploy, attach the custom domain `isthmus.channel` in the Render dashboard.

## Contact (shown on the site)

- Email: `hello@isthmus.channel`
- Nostr: `npub1sthmus7ltsyk9c6rdyuaga32jdr868u4qg2lmfjg3dl3g597ctdqa0uudg`
