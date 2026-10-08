// The mark drawn in the app (BrandMark), the icon source it mirrors, the
// generated favicon/manifest and the colours in index.html must all agree, and
// every icon index.html references must exist under public/.
import { existsSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { BRAND_NAME, MARK_GLYPH, MARK_TILE_RX } from "./brand";

const WEB = fileURLToPath(new URL("../..", import.meta.url));
const REPO = fileURLToPath(new URL("../../../..", import.meta.url));
const read = (p: string) => readFileSync(p, "utf8");

const source = read(`${REPO}/assets/brand/bank-ledger-mark.svg`);
const tokens = JSON.parse(read(`${REPO}/packages/tokens/tokens.json`)) as { color: Record<"light" | "dark", Record<string, string>> };
const html = read(`${WEB}/index.html`);
const manifest = JSON.parse(read(`${WEB}/public/site.webmanifest`)) as {
  name: string;
  short_name: string;
  theme_color: string;
  background_color: string;
  icons: { src: string; sizes: string; purpose?: string }[];
};

function rects(svg: string) {
  const glyph = svg.match(/<g id="glyph"[^>]*>([\s\S]*?)<\/g>/)?.[1] ?? "";
  return [...glyph.matchAll(/<rect ([^>]*)\/>/g)].map((m) => {
    const attr = (name: string) => Number(m[1]?.match(new RegExp(`\\b${name}="([\\d.]+)"`))?.[1] ?? 0);
    return { x: attr("x"), y: attr("y"), width: attr("width"), height: attr("height"), rx: attr("rx") };
  });
}

describe("brand", () => {
  it("BrandMark geometry matches assets/brand/bank-ledger-mark.svg", () => {
    expect(rects(source)).toEqual(MARK_GLYPH);
    expect(Number(source.match(/<rect id="tile"[^>]*\brx="([\d.]+)"/)?.[1])).toBe(MARK_TILE_RX);
  });

  it("keeps every glyph edge on an even unit, so 16px renders crisp", () => {
    for (const r of MARK_GLYPH) for (const v of [r.x, r.y, r.x + r.width, r.y + r.height]) expect(v % 2).toBe(0);
  });

  it("the generated favicon.svg carries the same glyph and both themes' token colours", () => {
    const fav = read(`${WEB}/public/favicon.svg`);
    for (const r of MARK_GLYPH) expect(fav).toContain(`<rect x="${r.x}" y="${r.y}" width="${r.width}" height="${r.height}" rx="${r.rx}"/>`);
    for (const c of [tokens.color.light.accent, tokens.color.light.bg, tokens.color.dark.accent, tokens.color.dark.bg]) expect(fav).toContain(c!);
    expect(fav).toContain("prefers-color-scheme:dark");
  });

  it("manifest is named Bank Ledger, uses token colours and ships a maskable icon", () => {
    expect(manifest.name).toBe(BRAND_NAME);
    expect(manifest.short_name).toBe(BRAND_NAME);
    expect(manifest.theme_color).toBe(tokens.color.light.bg);
    expect(manifest.background_color).toBe(tokens.color.light.bg);
    expect(manifest.icons.some((i) => i.purpose === "maskable" && i.sizes === "512x512")).toBe(true);
    for (const i of manifest.icons) expect(existsSync(`${WEB}/public${i.src}`), i.src).toBe(true);
  });

  it("index.html names the app, links existing icons and uses token theme colours", () => {
    expect(html).toContain(`<title>${BRAND_NAME}</title>`);
    const hrefs = [...html.matchAll(/<link rel="(?:icon|apple-touch-icon|manifest)"[^>]*href="([^"]+)"/g)].map((m) => m[1] ?? "");
    expect(hrefs).toEqual(["/favicon.svg", "/favicon-32.png", "/favicon-16.png", "/apple-touch-icon.png", "/site.webmanifest"]);
    for (const h of hrefs) expect(existsSync(`${WEB}/public${h}`), h).toBe(true);
    expect(html).toContain(`media="(prefers-color-scheme: light)" content="${tokens.color.light.bg}"`);
    expect(html).toContain(`media="(prefers-color-scheme: dark)" content="${tokens.color.dark.bg}"`);
  });
});
