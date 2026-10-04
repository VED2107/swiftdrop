/**
 * Bundles the browser client into the Flutter app, so the app (Windows, Android) can serve
 * it to phones without the app, the way the Node PC server does.
 *
 *   node scripts/sync-web-assets.mjs        → apps/swiftdrop/assets/web/** + manifest.txt
 *
 * Builds apps/web fresh with production settings (a test build points p2p at a local
 * rendezvous; that must never ship), then copies dist/ and writes manifest.txt: a content
 * hash on the first line, then every relative path. The app extracts the files once per
 * hash (lib/app/web_assets.dart).
 */
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { cpSync, existsSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { dirname, join, relative, sep } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const dist = join(root, "apps", "web", "dist");
const out = join(root, "apps", "swiftdrop", "assets", "web");

const env = { ...process.env };
delete env.VITE_SIGNAL_URL;
execFileSync("corepack", ["pnpm", "--filter", "@swiftdrop/web", "build"], { stdio: "inherit", cwd: root, env, shell: process.platform === "win32" });

rmSync(out, { recursive: true, force: true });
mkdirSync(out, { recursive: true });
cpSync(dist, out, { recursive: true });

const files = [];
(function walk(dir) {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) walk(p);
    else files.push(relative(out, p).split(sep).join("/"));
  }
})(out);
files.sort();
const hash = createHash("sha256");
for (const f of files) hash.update(f).update(readFileSync(join(out, f)));
writeFileSync(join(out, "manifest.txt"), [hash.digest("hex").slice(0, 16), ...files].join("\n") + "\n");
if (!existsSync(join(out, "index.html"))) throw new Error("web build has no index.html");
console.log(`✓ ${files.length} files → apps/swiftdrop/assets/web`);
