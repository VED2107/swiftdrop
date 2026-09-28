/**
 * Renders the brand icon to every size the apps need (Chromium via Playwright, so no
 * image toolchain is required) and packs a multi-size Windows .ico.
 *
 *   node scripts/build-icons.mjs
 *
 * Sources: assets/brand/swiftdrop-icon.svg (large sizes), swiftdrop-icon-small.svg (≤ 48 px,
 * thicker strokes so it stays legible in the taskbar and Explorer).
 */
import { chromium } from "@playwright/test";
import { copyFileSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const brand = join(root, "assets", "brand");
const big = readFileSync(join(brand, "swiftdrop-icon.svg"), "utf8");
const small = readFileSync(join(brand, "swiftdrop-icon-small.svg"), "utf8");

const browser = await chromium.launch();
const page = await browser.newPage();
async function render(svg, size, { pad = 0, bg = null } = {}) {
  await page.setViewportSize({ width: size, height: size });
  const inner = size - pad * 2;
  await page.setContent(
    `<html><body style="margin:0;background:${bg ?? "transparent"}"><div style="padding:${pad}px;width:${inner}px;height:${inner}px">${svg.replace("<svg ", `<svg width="${inner}" height="${inner}" `)}</div></body></html>`,
  );
  return page.screenshot({ omitBackground: !bg, clip: { x: 0, y: 0, width: size, height: size } });
}

const out = {};
for (const s of [16, 24, 32, 48]) out[s] = await render(small, s);
for (const s of [64, 128, 180, 192, 256, 512, 1024]) out[s] = await render(big, s);
// Android/PWA maskable: full-bleed background, mark inside the 80% safe zone.
// Full-bleed background, mark scaled into the central 80% safe zone.
const maskableSvg = big
  .replace(/<rect x="32" y="32" width="960" height="960" rx="236" fill="url\(#bg\)"\/>/, '<rect width="1024" height="1024" fill="url(#bg)"/>')
  .replace(/<rect x="33\.5"[^>]*\/>/, "")
  .replace(/(<circle cx="704")/, '<g transform="translate(102 102) scale(0.8)">$1')
  .replace(/<\/svg>/, "</g></svg>");
const maskable = await render(maskableSvg, 512);
await browser.close();

// ICO with PNG-compressed entries (Windows Vista+).
function ico(sizes) {
  const imgs = sizes.map((s) => out[s]);
  const header = Buffer.alloc(6 + 16 * imgs.length);
  header.writeUInt16LE(0, 0);
  header.writeUInt16LE(1, 2);
  header.writeUInt16LE(imgs.length, 4);
  let offset = header.length;
  imgs.forEach((img, i) => {
    const s = sizes[i];
    const e = 6 + 16 * i;
    header.writeUInt8(s >= 256 ? 0 : s, e);
    header.writeUInt8(s >= 256 ? 0 : s, e + 1);
    header.writeUInt8(0, e + 2);
    header.writeUInt8(0, e + 3);
    header.writeUInt16LE(1, e + 4);
    header.writeUInt16LE(32, e + 6);
    header.writeUInt32LE(img.length, e + 8);
    header.writeUInt32LE(offset, e + 12);
    offset += img.length;
  });
  return Buffer.concat([header, ...imgs]);
}

const write = (p, b) => {
  mkdirSync(dirname(p), { recursive: true });
  writeFileSync(p, b);
};
write(join(brand, "swiftdrop.ico"), ico([16, 24, 32, 48, 64, 128, 256]));
write(join(brand, "swiftdrop-1024.png"), out[1024]);
for (const dir of [join(root, "apps", "web", "public"), join(root, "apps", "site", "public")]) {
  write(join(dir, "icon-180.png"), out[180]);
  write(join(dir, "icon-192.png"), out[192]);
  write(join(dir, "icon-512.png"), out[512]);
  write(join(dir, "icon-maskable-512.png"), maskable);
  write(join(dir, "favicon.ico"), ico([16, 32, 48]));
  copyFileSync(join(brand, "swiftdrop-icon-small.svg"), join(dir, "favicon.svg"));
}
console.log("✓ icons: assets/brand/swiftdrop.ico, apps/web/public, apps/site/public");
