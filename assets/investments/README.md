# Investment images

One JPEG per holding look, named `<metal>-<form>.jpg` (`holdings_valuation` returns it as
`image_path`): 800 px on the long side, JPEG quality 82. They are uploaded to the public
Storage bucket `investment-images` with `scripts/brand/upload-investment-images.sh` (needs
`SUPABASE_URL` and `SUPABASE_SECRET_KEY`; `--dry-run` makes no requests). Clients load
`<SUPABASE_URL>/storage/v1/object/public/investment-images/<image_path>`.

**Downloaded, never drawn** (the bank-logo rule, `tasks/lessons.md`): each file is a published
photo, resized only. Every one is public domain or CC0, so no credit line is needed in the apps;
the sources are recorded here anyway.

| File | Shows | Source (Wikimedia Commons) | Author | Licence | Retrieved |
|---|---|---|---|---|---|
| `gold-bar.jpg` | two gold ingots on white | [Gold Ingots on white background.jpg](https://commons.wikimedia.org/wiki/File:Gold_Ingots_on_white_background.jpg) | Szaaman | Public domain | 2026-10-21 |
| `gold-coin.jpg` | 2018 American Liberty gold coin, obverse | [2018 American Liberty Eagle Obverse.jpg](https://commons.wikimedia.org/wiki/File:2018_American_Liberty_Eagle_Obverse.jpg) | United States Mint | Public domain (US government work) | 2026-10-21 |
| `gold-jewellery.jpg` | 916 (22K) gold bangles | [916 Bangles.jpg](https://commons.wikimedia.org/wiki/File:916_Bangles.jpg) | Sri Veerabadra Jewellers | CC0 | 2026-10-21 |
| `silver-bar.jpg` | Johnson Matthey 500 g 999 silver bar | [Johnson Matthey 500 grammes silver bullion.jpg](https://commons.wikimedia.org/wiki/File:Johnson_Matthey_500_grammes_silver_bullion.jpg) | Kallemax (English Wikipedia) | Public domain | 2026-10-21 |
| `silver-coin.jpg` | 2022 American Silver Eagle, obverse | [American Silver Eagle, obverse, 2022.jpg](https://commons.wikimedia.org/wiki/File:American_Silver_Eagle,_obverse,_2022.jpg) | United States Mint | Public domain (US government work) | 2026-10-21 |

Adding a look (a new form or metal): add the file here with its row, extend the `form` check in
the migration that owns `holdings`, and re-run the upload script against each project.
