import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    include: ["tests/*.spec.ts"],
    globalSetup: "./tests/vitest-setup.ts",
    isolate: true,
    fileParallelism: false,
    hookTimeout: 120000,
    testTimeout: 10000,
  },
});