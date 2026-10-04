/**
 * Windows installer for the Flutter app: packages apps/swiftdrop's release build with the
 * Inno Setup compiler shipped in node_modules (innosetup-compiler).
 *
 *   flutter build windows --release   (in apps/swiftdrop)
 *   pnpm build:installer              → release/SwiftDrop-Setup-<version>.exe
 */
import { execFileSync } from "node:child_process";
import { readFileSync, statSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
if (process.platform !== "win32") throw new Error("The installer is built on Windows.");
// The app's version lives in its pubspec ("version: 0.3.0+3" -> 0.3.0).
const version = /^version:\s*([0-9.]+)/m.exec(readFileSync(join(root, "apps", "swiftdrop", "pubspec.yaml"), "utf8"))[1];
statSync(join(root, "apps", "swiftdrop", "build", "windows", "x64", "runner", "Release", "swiftdrop.exe")); // built first
const iscc = join(root, "node_modules", "innosetup-compiler", "bin", "ISCC.exe");
execFileSync(iscc, [`/DAppVersion=${version}`, "/Q", join(root, "scripts", "installer", "SwiftDrop.iss")], { stdio: "inherit", cwd: join(root, "scripts", "installer") });
const out = join(root, "release", `SwiftDrop-Setup-${version}.exe`);
console.log(`✓ release/SwiftDrop-Setup-${version}.exe (${(statSync(out).size / 1e6).toFixed(1)} MB)`);
