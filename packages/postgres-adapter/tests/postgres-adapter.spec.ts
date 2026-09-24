import type { Model } from "@sigworkflow/core/adapters/database";
import { describe, expect, type Mock, test, vi } from "vitest";
import { adapterFor } from "../src/postgres-adapter";

const createPostgresTestAdapter = (mock?: Mock) => {
  return adapterFor(
    {
      query: mock ?? vi.fn().mockResolvedValue({ rows: [], rowCount: 0 }),
    },
    {
      models: {
        executionEvents: "execution_events",
        outbox: "outbox",
        stepExecutions: "step_executions",
        workflowExecutions: "workflow_executions",
        workflows: "workflows",
      },
    },
  );
};

describe("postgres-adapter", () => {
  test("adapterFor returns a DatabaseAdapter", () => {
    const adapter = createPostgresTestAdapter();

    expect(adapter).toBeDefined();
  });

  test("creates a valid adapter with custom query function", async () => {
    const mockQuery = vi
      .fn()
      .mockResolvedValue({ rows: [{ id: 1 }], rowCount: 1 });

    const adapter = createPostgresTestAdapter(mockQuery);

    const result = await adapter.create({
      model: "workflows",
      data: { name: "test-workflow" },
    });

    const expectedQuery = `INSERT INTO "workflows" ("name") VALUES ($1) RETURNING *`;
    const expectedValues = ["test-workflow"];

    const lastCall = mockQuery.mock.calls[mockQuery.mock.calls.length - 1];

    expect(lastCall[0]).toEqual(expectedQuery);
    expect(lastCall[1]).toEqual(expectedValues);

    expect(result).toEqual({ id: 1 });
  });

  test("throws error for unknown model", async () => {
    const adapter = createPostgresTestAdapter();

    await expect(
      adapter.create({
        model: "unknown_model" as Model,
        data: { name: "test" },
      }),
    ).rejects.toThrow("Unknown persistence model: unknown_model");
  });
});