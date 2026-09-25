import type { Model } from "@sigworkflow/core/adapters/database";
import { describe, expect, type Mock, test, vi } from "vitest";
import { adapterFor, parseBjsonFields } from "../src/postgres-adapter";

const createPostgresTestAdapter = (mock?: Mock) => {
  return adapterFor(
    {
      query: mock ?? vi.fn().mockResolvedValue({ rows: [], rowCount: 0 }),
    },
    {
      models: {
        workflowExecutions: "workflow_executions",
        workflows: "workflows",
      },
      fields: {
        workflowExecutions: {
          id: "id",
          workflowId: "workflow_id",
          status: "status",
          currentStep: "current_step",
          context: "context",
          outputs: "outputs",
          createdAt: "created_at",
          updatedAt: "updated_at",
        },
        workflows: {
          id: "id",
          name: "name",
          context: "context",
          definition: "definition",
          createdAt: "created_at",
        },
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

  test("parses JSON strings from JSONB fields", () => {
    const row = parseBjsonFields(
      "workflowExecutions",
      {
        context: '{"customerId":42}',
        outputs: '{"step":{"ok":true}}',
      },
      {
        models: {
          workflows: "workflows",
          workflowExecutions: "workflow_executions",
        },
        fields: {
          workflows: {
            id: "id",
            name: "name",
            context: "context",
            definition: "definition",
            createdAt: "created_at",
          },
          workflowExecutions: {
            id: "id",
            workflowId: "workflow_id",
            status: "status",
            currentStep: "current_step",
            context: "context",
            outputs: "outputs",
            createdAt: "created_at",
            updatedAt: "updated_at",
          },
        },
      },
    );

    expect(row).toEqual({
      context: { customerId: 42 },
      outputs: { step: { ok: true } },
    });
  });

  test("maps logical fields in SQL and returns logical JSONB fields", async () => {
    const mockQuery = vi.fn().mockResolvedValue({
      rows: [{ workflow_name: "example", workflow_context: '{"active":true}' }],
      rowCount: 1,
    });
    const adapter = adapterFor(
      { query: mockQuery },
      {
        models: {
          workflows: "workflow_records",
          workflowExecutions: "execution_records",
        },
        fields: {
          workflows: {
            id: "workflow_id",
            name: "workflow_name",
            context: "workflow_context",
            definition: "workflow_definition",
            createdAt: "created_on",
          },
          workflowExecutions: {
            id: "execution_id",
            workflowId: "workflow_id",
            status: "execution_status",
            currentStep: "current_step_id",
            context: "execution_context",
            outputs: "execution_outputs",
            createdAt: "created_on",
            updatedAt: "updated_on",
          },
        },
      },
    );

    const result = await adapter.findOne({
      model: "workflows",
      where: [{ field: "name", value: "example" }],
      select: ["name", "context"],
    });

    expect(mockQuery).toHaveBeenCalledWith(
      'SELECT "workflow_name" AS "name", "workflow_context" AS "context" FROM "workflow_records" WHERE "workflow_name" = $1 LIMIT 1',
      ["example"],
    );
    expect(result).toEqual({ name: "example", context: { active: true } });
  });

  test("serializes JSONB fields while inserting", async () => {
    const mockQuery = vi.fn().mockResolvedValue({
      rows: [{ workflow_id: "id-1", workflow_context: { active: true } }],
      rowCount: 1,
    });
    const adapter = adapterFor(
      { query: mockQuery },
      {
        models: {
          workflows: "workflow_records",
          workflowExecutions: "execution_records",
        },
        fields: {
          workflows: {
            id: "workflow_id",
            name: "workflow_name",
            context: "workflow_context",
            definition: "workflow_definition",
            createdAt: "created_on",
          },
          workflowExecutions: {
            id: "execution_id",
            workflowId: "workflow_id",
            status: "execution_status",
            currentStep: "current_step_id",
            context: "execution_context",
            outputs: "execution_outputs",
            createdAt: "created_on",
            updatedAt: "updated_on",
          },
        },
      },
    );

    const result = await adapter.create({
      model: "workflows",
      data: { context: { active: true }, name: "test-workflow" },
      select: ["id", "context"],
    });

    expect(mockQuery).toHaveBeenCalledWith(
      'INSERT INTO "workflow_records" ("workflow_context") VALUES ($1) RETURNING "workflow_id" AS "id", "workflow_context" AS "context"',
      ['{"active":true}'],
    );
    expect(result).toEqual({ id: "id-1", context: { active: true } });
  });
});