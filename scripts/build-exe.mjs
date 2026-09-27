/**
 * Packages the PC side as a single SwiftDrop.exe (Node single executable application).
 *
 *   pnpm build:exe            → release/SwiftDrop.exe
 *
 * 1. build the web app (Vite)
 * 2. bundle the server + workspace packages into one CommonJS file (esbuild)
 * 3. embed that bundle and every web asset into a SEA blob
 * 4. inject the blob into a copy of the running node.exe (postject)
 */
import { execFileSync } from "node:child_process";
import { copyFileSync, mkdirSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const work = join(root, "release", ".build");
const out = join(root, "release", process.platform === "win32" ? "SwiftDrop.exe" : "swiftdrop");
const webDist = join(root, "apps", "web", "dist");
const run = (cmd, args, opts = {}) => execFileSync(cmd, args, { stdio: "inherit", cwd: root, shell: process.platform === "win32", ...opts });

rmSync(work, { recursive: true, force: true });
mkdirSync(work, { recursive: true });

console.log("› building web app");
run("pnpm", ["--filter", "@swiftdrop/web", "build"]);

const assets = {};
const walk = (dir) => {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) walk(p);
    else assets[relative(webDist, p).split("\\").join("/")] = p;
  }
};
walk(webDist);
console.log(`› ${Object.keys(assets).length} web assets`);

console.log("› bundling server");
await build({
  entryPoints: [join(root, "apps", "server", "src", "sea.ts")],
  outfile: join(work, "server.cjs"),
  bundle: true,
  platform: "node",
  format: "cjs",
  target: "node22",
  minify: true,
  legalComments: "none",
  define: { __SWIFTDROP_ASSETS__: JSON.stringify(Object.keys(assets)) },
  logLevel: "warning",
});

writeFileSync(
  join(work, "sea-config.json"),
  JSON.stringify(
    {
      main: join(work, "server.cjs"),
      output: join(work, "sea-prep.blob"),
      disableExperimentalSEAWarning: true,
      useSnapshot: false,
      useCodeCache: true,
      assets,
    },
    null,
    2,
  ),
);

console.log("› generating SEA blob");
execFileSync(process.execPath, ["--experimental-sea-config", join(work, "sea-config.json")], { stdio: "inherit" });

console.log("› injecting into executable");
mkdirSync(dirname(out), { recursive: true });
rmSync(out, { force: true });
copyFileSync(process.execPath, out);
if (process.platform === "win32") {
  // node.exe is Authenticode-signed; injecting invalidates that signature. Strip it if signtool exists.
  try {
    execFileSync("signtool", ["remove", "/s", out], { stdio: "ignore" });
  } catch {
    /* signtool not installed: the exe still runs, just unsigned-with-broken-signature */
  }
}
run("npx", [
  "postject",
  out,
  "NODE_SEA_BLOB",
  join(work, "sea-prep.blob"),
  "--sentinel-fuse",
  "NODE_SEA_FUSE_fce680ab2cc467b6e072b8b5df1996b2",
  ...(process.platform === "darwin" ? ["--macho-segment-name", "NODE_SEA"] : []),
]);

rmSync(work, { recursive: true, force: true });
const mb = (statSync(out).size / 1e6).toFixed(1);
console.log(`\n✓ ${relative(root, out)} (${mb} MB)`);
