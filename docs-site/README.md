# FleetLM Documentation Site

This directory contains the configuration for the public documentation site built with [Docusaurus](https://docusaurus.io/). The site consumes the Markdown files stored in `../docs`.

## Local development

Install Node.js 18 (or newer), then install dependencies and start the dev server:

```bash
cd docs-site
npm install
npm run start
```

By default Docusaurus serves the site at http://localhost:3000/ and watches the `docs/` directory for changes.

## Production build

```bash
cd docs-site
npm install
npm run build
```

The static files are emitted to `docs-site/build/`. You can deploy that folder to any static hosting service (GitHub Pages, Netlify, Vercel, S3, etc.).

### Base URL / Site URL

By default the docs build assumes it will be served from the root of a domain (`/`).
Override either value via environment variables when building:

```bash
DOCUSAURUS_SITE_URL="https://cpluss.github.io" \
DOCUSAURUS_BASE_URL="/fleetlm/" \
npm run build
```

That setup mirrors the old GitHub Pages style (`https://cpluss.github.io/fleetlm/`).

## GitHub Pages quick start

To publish on GitHub Pages using GitHub Actions:

1. Enable Pages for the repository (Settings → Pages) and point it to the `gh-pages` branch.
2. Add a workflow similar to the snippet below in `.github/workflows/docs.yml`:

   ```yaml
   name: Docs
   on:
     push:
       branches: [main]
   jobs:
     build:
       runs-on: ubuntu-latest
       steps:
         - uses: actions/checkout@v4
         - uses: actions/setup-node@v4
           with:
             node-version: 18
             cache: npm
             cache-dependency-path: docs-site/package-lock.json
         - run: cd docs-site && npm install && npm run build
         - uses: peaceiris/actions-gh-pages@v4
           with:
             github_token: ${{ secrets.GITHUB_TOKEN }}
             publish_dir: docs-site/build
             force_orphan: true
   ```

The workflow keeps the documentation in sync with every push to `main` while leaving the Markdown source co-located with the codebase.
