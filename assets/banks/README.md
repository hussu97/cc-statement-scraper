# Bank logos

One PNG per `banks.bank_code`: `<BANK_CODE>.png`, 256×256, transparent background,
the bank's mark centred inside an 8% padding box (215 px), 128-colour palette PNG.
They are uploaded to the public Storage bucket `bank-logos` with
`scripts/brand/upload-bank-logos.sh` (needs `SUPABASE_URL` and `SUPABASE_SECRET_KEY`;
`--dry-run` makes no requests), and `banks.logo_path` points at `<BANK_CODE>.png`.

Every file was built from a vector source (SVG sanitised: no scripts, event
handlers or external references; rasterised with resvg, never shipped as SVG).
Where the bank's own square icon is the mark alone, the PNG uses that mark rather
than the full wordmark so it stays legible at 24–32 px.

| Code | Bank | Mark used | Vector source | Confirmed against | Retrieved |
|---|---|---|---|---|---|
| `ADCB` | Abu Dhabi Commercial Bank | red emblem (no wordmark) | Wikimedia Commons, [`Abu_Dhabi_Commercial_Bank_logo.svg`](https://commons.wikimedia.org/wiki/File:Abu_Dhabi_Commercial_Bank_logo.svg) ([file](https://upload.wikimedia.org/wikipedia/commons/2/25/Abu_Dhabi_Commercial_Bank_logo.svg)), emblem paths only | adcb.com favicon / [apple-touch-icon](https://www.adcb.com/en/system/assets/toolkit/favicon-assets/personal/apple-touch-icon.png) (the same emblem alone) | 2026-10-08 |
| `EIB` | Emirates Islamic | "EI" bars glyph | emiratesislamic.ae header logo [`logo_white_ei_new.svg`](https://www.emiratesislamic.ae/-/media/ei/images/header/logo_white_ei_new.svg) (white), glyph paths only, recoloured `#3e1051` | emiratesislamic.ae [apple-touch-icon](https://www.emiratesislamic.ae/-/media/ei/images/header/EI_touch_icon.jpg) (colour sampled from it) | 2026-10-08 |
| `ENBD` | Emirates NBD | framed mark (no wordmark) | emiratesnbd.com header logo [`horizontal_logo.svg`](https://www.emiratesnbd.com/-/media/enbd/images/logos/horizontal_logo.svg) (white), mark only, recoloured `#072447` | emiratesnbd.com [touch icon](https://www.emiratesnbd.com/-/media/enbd/images/logos/emiratesnbd_touch-icon.png) (colour sampled from it) | 2026-10-08 |
| `FAB` | First Abu Dhabi Bank | "FAB" + red swoosh (Arabic and full name dropped) | Wikimedia Commons, [`First_Abu_Dhabi_Bank_Logo.svg`](https://commons.wikimedia.org/wiki/File:First_Abu_Dhabi_Bank_Logo.svg) ([file](https://upload.wikimedia.org/wikipedia/commons/2/22/First_Abu_Dhabi_Bank_Logo.svg)) | bankfab.com header logo [`fab-logo.svg`](https://www.bankfab.com/-/media/project/fab2/fab2/data/media/img/fab-logo.svg) (same shapes, white variant) | 2026-10-08 |
| `MASHREQ` | Mashreq | sunburst (no wordmark) | Wikipedia, [`Mashreq_logo_2022.svg`](https://en.wikipedia.org/wiki/File:Mashreq_logo_2022.svg) ([file](https://upload.wikimedia.org/wikipedia/en/5/5c/Mashreq_logo_2022.svg)), sunburst paths only | mashreq.com [favicon](https://www.mashreq.com/dist/mashreq-reactjs/favicon.ico) (the same sunburst alone) | 2026-10-08 |
| `SIB` | Sharjah Islamic Bank | "SIB" letters (calligraphy and Arabic name dropped) | sib.ae header logo [`sib-logo.svg`](https://sib.ae/images/default-source/default-album/sib-logo.svg) (white), letter paths only, recoloured `#001489` | sib.ae brand blue `rgb(0, 20, 137)`; the SIB app icon is the same letters | 2026-10-08 |
| `WIO` | Wio Bank | the official square icon: white "wio" wordmark on the Wio purple, **unmodified** (300×300 RGBA, not the 256 palette format) | none: Wio publishes no vector logo; the PNG is the bank's own file | wio.io [`logo.png`](https://wio.io/logo.png), the site's published logo (also its Gmail avatar) | 2026-10-12 |
| `DFM` | Dubai Financial Market (iVESTOR card) | the official square icon: black emblem on white, **unmodified** (180×180 grayscale, not the 256 palette format) | none used: the PNG is DFM's own file, not redrawn | dfm.ae [`apple-touch-icon.png`](https://www.dfm.ae/apple-touch-icon.png), the site's published touch icon (its header logo [`dfm-new-logo-white.svg`](https://www.dfm.ae/icons/dfm-new-logo-white.svg) is the same emblem) | 2026-10-26 |

**Trademarks.** Each logo is a trademark of the bank named in its row; it is used
only to identify the user's own accounts with that bank. The Commons / Wikipedia
licence tags (public domain as simple text/shapes, or fair use) cover the files on
those sites, not the trademarks.

**Dark mode.** The ENBD (navy), SIB (blue), EIB (purple) and FAB (navy text) marks
have low contrast on a dark background. Render the logos on a light chip (e.g. a
white rounded square) in dark mode rather than directly on the dark surface.

**Downloaded, never drawn.** A logo is the bank's own published file (or a vector the bank
publishes), downloaded from the bank's site or a source that hosts it; never a mark redrawn or
re-rendered by hand. WIO is used exactly as wio.io serves it.

**Updating a logo.** Replace `<BANK_CODE>.png` (same size and naming), add the new
source to this table, and re-run the upload script (objects are upserted).
