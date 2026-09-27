import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    include: ["packages/*/src/**/*.test.ts", "apps/*/src/**/*.test.ts", "tests/integration/**/*.test.ts"],
    testTimeout: 60_000,
    pool: "forks",
  },
});
