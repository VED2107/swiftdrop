/**
 * Windows installer: builds SwiftDrop.exe, then compiles scripts/installer/SwiftDrop.iss
 * with the Inno Setup compiler shipped in node_modules (innosetup-compiler).
 *
 *   pnpm build:installer   → release/SwiftDrop.exe + release/SwiftDrop-Setup-<version>.exe
 */
import { execFileSync } from "node:child_process";
import { readFileSync, statSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
if (process.platform !== "win32") throw new Error("The installer is built on Windows.");
const version = JSON.parse(readFileSync(join(root, "package.json"), "utf8")).version;
if (!process.argv.includes("--skip-exe")) execFileSync(process.execPath, [join(root, "scripts", "build-exe.mjs")], { stdio: "inherit", cwd: root });
const iscc = join(root, "node_modules", "innosetup-compiler", "bin", "ISCC.exe");
execFileSync(iscc, [`/DAppVersion=${version}`, "/Q", join(root, "scripts", "installer", "SwiftDrop.iss")], { stdio: "inherit", cwd: join(root, "scripts", "installer") });
const out = join(root, "release", `SwiftDrop-Setup-${version}.exe`);
console.log(`✓ release/SwiftDrop-Setup-${version}.exe (${(statSync(out).size / 1e6).toFixed(1)} MB)`);
