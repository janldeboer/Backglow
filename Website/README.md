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

## Privacy

The privacy policy relies on nginx and Traefik keeping no access logs, as set in `deploy/`. When the app's privacy-relevant behavior changes (network access, telemetry, what is stored), update `public/datenschutz/` before releasing.
