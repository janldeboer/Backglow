# backglow.jandeboer.de

Static landing and docs page in German (`/`) and English (`/en/`), like the app. Every page links to its counterpart and declares it with `hreflang`; keep both versions in step when editing. No build step, no scripts, no cookies, no external resources.

| German | English |
| --- | --- |
| `/` | `/en/` |
| `/docs/` | `/en/docs/` |
| `/datenschutz/` | `/en/privacy/` |
| `/impressum/` | `/en/legal/` |

- `public/`: the site. Screenshots in `public/assets/screens/<language>/` come from `Backglow.app --screenshots <folder> -AppleLanguages "(en)"` (dark variants, converted to 1600 px JPEG), so they show the demo image and no private screen content. `assets/icon.png` is an `ictool` render of `AppBundle/Backglow.icon`.
- `deploy/`: nginx config, Compose project `backglow-website` and the Traefik router file.

## Search and AI metadata

Some facts appear more than once and must be kept in step by hand:

- The FAQ on `/` and `/en/` is repeated word for word in the page's `FAQPage` JSON-LD, and the guide's steps are summarized in `HowTo` JSON-LD on `/docs/` and `/en/docs/`. Change the JSON-LD whenever the visible text changes; Google treats mismatches as spam.
- On a new release, update the version and DMG URL in the download buttons, in the `SoftwareApplication` JSON-LD (`softwareVersion`, `downloadUrl`, `releaseNotes`) and in `llms.txt`.
- `llms.txt` is a plain-English summary for AI assistants and crawlers. Keep its key facts true to the app.
- `sitemap.xml` lists every page with its `hreflang` counterparts; bump `lastmod` for pages whose content changed.

Preview locally:

```sh
python3 -m http.server 4341 --bind 127.0.0.1 --directory Website/public
```

## Hosting

Odysseus (`167.233.73.150`), reached through the `*.jandeboer.de` wildcard record.

- Releases in `/opt/backglow-website/releases/<date>-NN`, `current` points to the active one.
- Container `backglow-website-web-1` on the existing `coolify` network, alias `backglow-website-web`, nginx on internal port 8080, no published host ports, read-only mounts.
- Router file `/data/coolify/proxy/dynamic/backglow-website.yaml`, Let's Encrypt through the existing resolver, HTTP redirects to HTTPS. No Project Access middleware.
- No access logs in nginx or Traefik, which the privacy policy relies on.

## Update or roll back

Copy only `public/` and `deploy/` into a new release folder, packed without AppleDouble or `.DS_Store` files (for example with Python's `tarfile`). In its `deploy/` folder run:

```sh
docker compose config -q
docker compose run --rm --no-deps -T web nginx -t </dev/null
docker compose up -d --wait --wait-timeout 60 </dev/null
```

Then point `current` at the new release. The container mounts absolute release paths, so a rollback means running the same commands in the previous release, not only moving the symlink. Replace the router file only when `deploy/traefik.yaml` changed.

When the app's privacy-relevant behavior changes (network access, telemetry, what is stored), update `public/datenschutz/` before releasing.
