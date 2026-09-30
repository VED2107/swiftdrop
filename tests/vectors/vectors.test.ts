import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { buildVectors, VECTORS_PATH } from "./generate.ts";

describe("cross-language vectors", () => {
  it("the committed vectors still match the TypeScript implementation (run `pnpm vectors` after an intended change)", async () => {
    const committed: unknown = JSON.parse(readFileSync(VECTORS_PATH, "utf8"));
    expect(JSON.parse(JSON.stringify(await buildVectors()))).toEqual(committed);
  });
});
