import { vi } from "vitest";
import type { MQAdapter } from "../../src/adapters/mq";

export const mockMQAdapter: MQAdapter = {
  spawnWorker: vi.fn(),
  publish: vi.fn(),
};