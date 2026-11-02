import { defineConfig } from "vitest/config";

import { sidecarEnvPlugin } from "./vite.config";

// Tests run the same module graph as the app, including its one virtual
// module. Without this plugin `api.ts` cannot resolve `virtual:sidecar-env`.
// Empty values are correct here: tests never talk to a sidecar, and the
// browser-mode wiring belongs to `vite.config.ts`'s serve path.
export default defineConfig({
  plugins: [sidecarEnvPlugin("", false)],
  test: {
    environment: "node",
    include: ["src/**/*.test.ts"],
  },
});
