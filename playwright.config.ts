import { defineConfig } from "@playwright/test";

// E2E runs the real server in its test-only mode: localhost = the PC, 127.0.0.1 = the phone.
export default defineConfig({
  testDir: "tests/e2e",
  timeout: 90_000,
  use: { trace: "retain-on-failure" },
  webServer: {
    command: "pnpm build && npx tsx apps/server/src/main.ts",
    url: "http://localhost:8799/api/ping",
    reuseExistingServer: false,
    timeout: 120_000,
    env: {
      SWIFTDROP_E2E: "1",
      SWIFTDROP_PORT: "8799",
      SWIFTDROP_DEST: "test-results/e2e-dest",
      SWIFTDROP_STATE_DIR: "test-results/e2e-state",
      SWIFTDROP_OUTBOX: "test-results/e2e-outbox",
      SWIFTDROP_LOG: "warn",
    },
  },
});
