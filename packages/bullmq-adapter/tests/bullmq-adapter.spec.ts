import { describe, expect, test, vi } from "vitest";
import { bullmq } from "../src/bullmq-adapter.js";

const { mockQueueAdd, MockQueue, MockWorker } = vi.hoisted(() => {
  const mockQueueAdd = vi.fn().mockResolvedValue({ id: "job-1" });
  class MockQueue {
    static calls: any[][] = [];
    constructor(...args: any[]) {
      MockQueue.calls.push(args);
    }
    add = mockQueueAdd;
  }
  class MockWorker {
    static calls: any[][] = [];
    constructor(...args: any[]) {
      MockWorker.calls.push(args);
    }
  }
  return { mockQueueAdd, MockQueue, MockWorker };
});

vi.mock("bullmq", () => {
  return {
    Queue: MockQueue,
    Worker: MockWorker,
  };
});

describe("bullmq-adapter", () => {
  test("creates MQAdapter and publishes message to queue", async () => {
    const factory = bullmq({ connection: { host: "localhost", port: 6379 } });
    const adapter = factory({ jobQueueName: "test-queue", concurrency: 3 });

    expect(adapter).toBeDefined();
    expect(MockQueue.calls[MockQueue.calls.length - 1]).toEqual([
      "test-queue",
      expect.objectContaining({
        connection: { host: "localhost", port: 6379 },
      }),
    ]);

    await adapter.publish("execute-step", {
      executionId: "exec-123",
      stepId: "step-1",
    });

    expect(mockQueueAdd).toHaveBeenCalledWith(
      "execute-step",
      { executionId: "exec-123", stepId: "step-1" },
      {},
    );
  });

  test("spawnWorker instantiates Worker and connects runner", async () => {
    const factory = bullmq({ connection: { host: "localhost", port: 6379 } });
    const adapter = factory({ jobQueueName: "test-queue", concurrency: 3 });

    const runnerMock = vi.fn().mockResolvedValue(undefined);
    adapter.spawnWorker(runnerMock);

    expect(MockWorker.calls[MockWorker.calls.length - 1]).toEqual([
      "test-queue",
      expect.any(Function),
      expect.objectContaining({ concurrency: 3 }),
    ]);

    const processor = MockWorker.calls[MockWorker.calls.length - 1][1];
    await processor({ data: { executionId: "exec-123" } });
    expect(runnerMock).toHaveBeenCalledWith({ executionId: "exec-123" });
  });
});
