// Usage: node tests/performance/profile-summary.mjs <file.cpuprofile> [top]
// Self time per function (and per source file), from a V8 .cpuprofile.
import { readFileSync } from "node:fs";
const [file, topArg] = process.argv.slice(2);
const prof = JSON.parse(readFileSync(file, "utf8"));
const self = new Map();
const byId = new Map(prof.nodes.map((n) => [n.id, n]));
const dt = new Map();
for (let i = 0; i < prof.samples.length; i++) dt.set(prof.samples[i], (dt.get(prof.samples[i]) ?? 0) + (prof.timeDeltas[i] ?? 0));
let total = 0;
const byFile = new Map();
for (const [id, us] of dt) {
  const n = byId.get(id);
  const cf = n.callFrame;
  const key = `${cf.functionName || "(anon)"}  ${cf.url.split(/[\/]/).slice(-2).join("/")}:${cf.lineNumber + 1}`;
  self.set(key, (self.get(key) ?? 0) + us);
  const f = cf.url ? cf.url.split(/[\/]/).slice(-2).join("/") : cf.functionName;
  byFile.set(f, (byFile.get(f) ?? 0) + us);
  total += us;
}
const top = Number(topArg ?? 25);
const show = (m, title) => {
  console.log(`\n${title} (total ${(total / 1000).toFixed(0)} ms sampled)`);
  for (const [k, v] of [...m].sort((a, b) => b[1] - a[1]).slice(0, top)) console.log(`${((v / total) * 100).toFixed(1).padStart(5)}%  ${(v / 1000).toFixed(0).padStart(6)} ms  ${k}`);
};
show(self, "self time by function");
show(byFile, "self time by file");
