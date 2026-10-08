#!/usr/bin/env node
// Renders every Bank Ledger icon from ONE source: assets/brand/bank-ledger-mark.svg.
//
//   pnpm brand:icons            write apps/web/public/* and assets/brand/ios/*
//   pnpm brand:icons --check    exit 1 if any generated file is stale
//
// Colours come from packages/tokens/tokens.json (light accent + bg, dark accent
// + bg); the script fails if the source SVG's colours drift from the tokens.
// Outputs:
//   apps/web/public/favicon.svg            rounded tile, dark-mode aware (prefers-color-scheme)
//   apps/web/public/favicon-16.png / -32   rounded tile, light
//   apps/web/public/apple-touch-icon.png   180, full-bleed square (iOS rounds it)
//   apps/web/public/icon-192.png / -512    full-bleed square; the glyph sits inside the
//                                          maskable safe zone (radius 40%)
//   apps/web/public/site.webmanifest
//   assets/brand/ios/AppIcon-1024.png      opaque RGB, no alpha, square corners (iOS masks it)
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { deflateSync } from "node:zlib";
import { Resvg } from "@resvg/resvg-js";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const SOURCE = join(ROOT, "assets/brand/bank-ledger-mark.svg");
const PUBLIC = join(ROOT, "apps/web/public");
const IOS = join(ROOT, "assets/brand/ios");
const CHECK = process.argv.includes("--check");

const tokens = JSON.parse(readFileSync(join(ROOT, "packages/tokens/tokens.json"), "utf8"));
const COLORS = {
  light: { tile: tokens.color.light.accent, glyph: tokens.color.light.bg },
  dark: { tile: tokens.color.dark.accent, glyph: tokens.color.dark.bg },
};

// ---------- parse the source ----------
const source = readFileSync(SOURCE, "utf8");
const viewBox = source.match(/viewBox="([^"]+)"/)?.[1];
if (viewBox !== "0 0 32 32") throw new Error(`source viewBox must be "0 0 32 32", got ${viewBox}`);
const tileRx = Number(source.match(/<rect id="tile"[^>]*\brx="([\d.]+)"/)?.[1] ?? NaN);
const glyphBody = source.match(/<g id="glyph"[^>]*>([\s\S]*?)<\/g>/)?.[1]?.trim();
if (!glyphBody || Number.isNaN(tileRx)) throw new Error("source needs <rect id=\"tile\" rx=…> and <g id=\"glyph\">");
const glyph = glyphBody
  .split("\n")
  .map((l) => l.trim())
  .filter(Boolean)
  .join("");

// The source's own colours must be the token values.
const styleFills = [...source.matchAll(/\.(tile|glyph)\s*\{\s*fill:\s*(#[0-9a-fA-F]{6});?\s*\}/g)].map((m) => [m[1], m[2].toUpperCase()]);
const expected = [
  ["tile", COLORS.light.tile],
  ["glyph", COLORS.light.glyph],
  ["tile", COLORS.dark.tile],
  ["glyph", COLORS.dark.glyph],
].map(([k, v]) => [k, v.toUpperCase()]);
if (JSON.stringify(styleFills) !== JSON.stringify(expected)) {
  throw new Error(
    `assets/brand/bank-ledger-mark.svg colours drifted from packages/tokens.\n  source: ${JSON.stringify(styleFills)}\n  tokens: ${JSON.stringify(expected)}`,
  );
}

// ---------- compose ----------
/** Flat SVG in one theme. rx = 0 gives a full-bleed square for app icons. */
function flatSvg(theme, rx) {
  const c = COLORS[theme];
  return (
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32">` +
    `<rect width="32" height="32" rx="${rx}" fill="${c.tile}"/>` +
    `<g fill="${c.glyph}">${glyph}</g></svg>`
  );
}

const faviconSvg =
  `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32">` +
  `<style>.t{fill:${COLORS.light.tile}}.g{fill:${COLORS.light.glyph}}` +
  `@media (prefers-color-scheme:dark){.t{fill:${COLORS.dark.tile}}.g{fill:${COLORS.dark.glyph}}}</style>` +
  `<rect class="t" width="32" height="32" rx="${tileRx}"/><g class="g">${glyph}</g></svg>\n`;

function render(svg, size) {
  return new Resvg(svg, { fitTo: { mode: "width", value: size }, shapeRendering: 2 }).render();
}

// ---------- PNG without alpha (App Store rejects an icon with an alpha channel) ----------
const CRC_TABLE = Array.from({ length: 256 }, (_, n) => {
  let c = n;
  for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  return c >>> 0;
});
function crc32(buf) {
  let c = 0xffffffff;
  for (const b of buf) c = CRC_TABLE[(c ^ b) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}
function chunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length);
  const body = Buffer.concat([Buffer.from(type, "ascii"), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(body));
  return Buffer.concat([len, body, crc]);
}
function opaqueRgbPng(image) {
  const { width, height } = image;
  const rgba = image.pixels;
  const raw = Buffer.alloc((width * 3 + 1) * height);
  for (let y = 0; y < height; y++) {
    const row = y * (width * 3 + 1);
    raw[row] = 0; // filter: none
    for (let x = 0; x < width; x++) {
      const i = (y * width + x) * 4;
      if (rgba[i + 3] !== 255) throw new Error(`iOS icon pixel (${x},${y}) is not opaque`);
      raw.set(rgba.subarray(i, i + 3), row + 1 + x * 3);
    }
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8; // bit depth
  ihdr[9] = 2; // colour type: truecolour (RGB, no alpha)
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", ihdr),
    chunk("IDAT", deflateSync(raw, { level: 9 })),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}

const manifest = {
  name: "Bank Ledger",
  short_name: "Bank Ledger",
  description: "Credit-card spending from statements and bank SMS.",
  start_url: "/",
  scope: "/",
  display: "standalone",
  theme_color: tokens.color.light.bg,
  background_color: tokens.color.light.bg,
  icons: [
    { src: "/icon-192.png", sizes: "192x192", type: "image/png", purpose: "any" },
    { src: "/icon-512.png", sizes: "512x512", type: "image/png", purpose: "any" },
    { src: "/icon-512.png", sizes: "512x512", type: "image/png", purpose: "maskable" },
    { src: "/favicon.svg", sizes: "any", type: "image/svg+xml" },
  ],
};

/** @type {[string, Buffer | string][]} */
const outputs = [
  [join(PUBLIC, "favicon.svg"), faviconSvg],
  [join(PUBLIC, "favicon-16.png"), render(flatSvg("light", tileRx), 16).asPng()],
  [join(PUBLIC, "favicon-32.png"), render(flatSvg("light", tileRx), 32).asPng()],
  [join(PUBLIC, "apple-touch-icon.png"), render(flatSvg("light", 0), 180).asPng()],
  [join(PUBLIC, "icon-192.png"), render(flatSvg("light", 0), 192).asPng()],
  [join(PUBLIC, "icon-512.png"), render(flatSvg("light", 0), 512).asPng()],
  [join(PUBLIC, "site.webmanifest"), JSON.stringify(manifest, null, 2) + "\n"],
  [join(IOS, "AppIcon-1024.png"), opaqueRgbPng(render(flatSvg("light", 0), 1024))],
];

let stale = 0;
for (const [path, data] of outputs) {
  const buf = Buffer.isBuffer(data) ? data : Buffer.from(data);
  const rel = relative(ROOT, path);
  if (CHECK) {
    let current = null;
    try {
      current = readFileSync(path);
    } catch {
      /* missing */
    }
    if (!current || !current.equals(buf)) {
      console.error(`stale: ${rel}`);
      stale++;
    }
  } else {
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(path, buf);
    console.log(`wrote ${rel} (${buf.length} bytes)`);
  }
}
if (CHECK && stale) {
  console.error(`${stale} brand file(s) out of date: run \`pnpm brand:icons\``);
  process.exit(1);
}
