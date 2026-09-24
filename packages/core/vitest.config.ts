import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    include: ["**/*.spec.ts"],
    globalSetup: "./tests/vitest-setup.ts",
    isolate: false,
    fileParallelism: false,
    hookTimeout: 120000,
  },
});