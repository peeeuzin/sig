import { describe, expect, it } from "vitest";
import { NextAction, Node } from "../src/node/index.js";
import { WorkflowDefinition } from "../src/workflow/definition.js";

class EchoNode extends Node<{ value: string }, { value: string }> {
  async run() {
    return this.next({ value: this.params.value });
  }
}

describe("core", () => {
  it("builds workflow steps in insertion order with retry policy", () => {
    const definition = WorkflowDefinition.define("sample")
      .step("first", {
        name: "First",
        execute: new EchoNode().execute({ value: "hello" }),
        retry: { maxAttempts: 3, delayMs: 100 },
      })
      .step("second", {
        name: "Second",
        execute: new EchoNode().execute({ value: "world" }),
      });

    expect(definition.build()).toEqual({
      name: "sample",
      definition: {
        first: {
          name: "First",
          execute: { id: "EchoNode", params: { value: "hello" } },
          retry: { maxAttempts: 3, delayMs: 100 },
        },
        second: {
          name: "Second",
          execute: { id: "EchoNode", params: { value: "world" } },
          retry: undefined,
        },
      },
    });
  });

  it("creates a node definition and returns its output", async () => {
    const node = new EchoNode();
    expect(node.execute({ value: "ok" })).toEqual({
      id: "EchoNode",
      params: { value: "ok" },
    });
    node.setExecutionContext({}, { value: "ok" }, {} as never);
    await expect(node.run()).resolves.toEqual({
      nextStep: NextAction.NEXT,
      output: { value: "ok" },
    });
  });
});