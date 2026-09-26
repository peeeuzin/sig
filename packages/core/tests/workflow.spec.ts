import { describe, expect, it } from "vitest";
import { WorkflowEngine } from "../src/index.js";
import { NextAction, Node } from "../src/node/index.js";
import { WorkflowDefinition } from "../src/workflow/definition.js";
import { mockDatabaseAdapter } from "./fixture/database.js";
import { mockMQAdapter } from "./fixture/mq.js";

class TestNode extends Node {
  async run() {
    return this.next();
  }
}

describe("workflow", () => {
  it("should build workflow steps in insertion order with retry policy", () => {
    const definition = WorkflowDefinition.define("sample")
      .step("first", {
        name: "First",
        execute: new TestNode().execute({ value: "hello" }),
        retry: { maxAttempts: 3, delayMs: 100 },
      })
      .step("second", {
        name: "Second",
        execute: new TestNode().execute({ value: "world" }),
      });

    expect(definition.build()).toEqual({
      name: "sample",
      definition: {
        first: {
          name: "First",
          execute: { id: "TestNode", params: { value: "hello" } },
          next: NextAction.NEXT,
          retry: { maxAttempts: 3, delayMs: 100 },
        },
        second: {
          name: "Second",
          execute: { id: "TestNode", params: { value: "world" } },
          next: NextAction.NEXT,
          retry: undefined,
        },
      },
    });
  });

  it("should build workflow steps in insertion order without retry policy", () => {
    const definition = WorkflowDefinition.define("sample")
      .step("first", {
        name: "First",
        execute: new TestNode().execute({ value: "hello" }),
        next: NextAction.END,
      })
      .step("second", {
        name: "Second",
        execute: new TestNode().execute({ value: "world" }),
        retry: { maxAttempts: 3, delayMs: 100 },
      });

    expect(definition.build()).toEqual({
      name: "sample",
      definition: {
        first: {
          name: "First",
          execute: { id: "TestNode", params: { value: "hello" } },
          next: NextAction.END,
          retry: undefined,
        },
        second: {
          name: "Second",
          execute: { id: "TestNode", params: { value: "world" } },
          next: NextAction.NEXT,
          retry: { maxAttempts: 3, delayMs: 100 },
        },
      },
    });
  });

  it("should create a workflow", async () => {
    const engine = new WorkflowEngine({
      db: mockDatabaseAdapter({ create: async (args) => args.data as any }),
      mq: mockMQAdapter,
      nodes: [new TestNode()],
    });

    const definition = WorkflowDefinition.define("sample")
      .step("first", {
        name: "First",
        execute: new TestNode().execute({ value: "hello" }),
      })
      .step("second", {
        name: "Second",
        execute: new TestNode().execute({ value: "world" }),
      });

    const workflow = await engine.spawn(definition, { userId: "123" });

    expect(workflow.snapshot.definition).toEqual({
      first: {
        name: "First",
        execute: { id: "TestNode", params: { value: "hello" } },
        next: NextAction.NEXT,
        retry: undefined,
      },
      second: {
        name: "Second",
        execute: { id: "TestNode", params: { value: "world" } },
        next: NextAction.NEXT,
        retry: undefined,
      },
    });
    expect(workflow.snapshot.context).toEqual({ userId: "123" });
    expect(workflow.snapshot.name).toEqual("sample");
  });

  it("should create a execution", async () => {
    const engine = new WorkflowEngine({
      db: mockDatabaseAdapter({ create: async (args) => args.data as any }),
      mq: mockMQAdapter,
      nodes: [new TestNode()],
    });

    const definition = WorkflowDefinition.define("sample")
      .step("first", {
        name: "First",
        execute: new TestNode().execute({ value: "hello" }),
      })
      .step("second", {
        name: "Second",
        execute: new TestNode().execute({ value: "world" }),
      });

    const workflow = await engine.spawn(definition, { userId: "123" });
    const execution = await workflow.spawn({ postId: "456" });

    expect(execution.snapshot.workflowId).toEqual(workflow.snapshot.id);
    expect(execution.snapshot.context).toEqual({ postId: "456" });
    expect(execution.snapshot.status).toEqual("pending");
    expect(execution.outputs).toEqual({});

    expect(execution.workflow.snapshot.context).toEqual({ userId: "123" });
  });
});