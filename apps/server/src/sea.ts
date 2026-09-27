import { createHash } from "node:crypto";
import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { start } from "./start.ts";

/**
 * Entry for the packaged SwiftDrop.exe (Node single executable application).
 * The built web app ships inside the executable as SEA assets; on launch we unpack it
 * once into a per-version cache folder and point the normal static server at it.
 */
declare const __SWIFTDROP_ASSETS__: string[];

function unpackWebApp(): string {
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const sea = require("node:sea") as { getAsset(key: string): ArrayBuffer; isSea(): boolean };
  const names = __SWIFTDROP_ASSETS__;
  const hash = createHash("sha256");
  for (const n of names) hash.update(n).update(new Uint8Array(sea.getAsset(n)));
  const base = process.env.LOCALAPPDATA ?? join(homedir(), ".swiftdrop");
  const root = join(base, "SwiftDrop", `web-${hash.digest("hex").slice(0, 12)}`);
  if (!existsSync(join(root, "index.html"))) {
    for (const n of names) {
      const target = join(root, ...n.split("/"));
      mkdirSync(dirname(target), { recursive: true });
      writeFileSync(target, new Uint8Array(sea.getAsset(n)));
    }
  }
  return root;
}

process.env.SWIFTDROP_WEB_ROOT = unpackWebApp();
process.title = "SwiftDrop";
void start({ packaged: true });
