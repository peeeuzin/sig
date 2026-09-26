import { evaluate, NextAction } from "@sigworkflow/core";
import { describe, expect, it } from "vitest";
import { IfNode } from "../src/ifNode.js";

describe("IfNode", () => {
  it("should evaluate context fields and routes to the matching step", async () => {
    const node = new IfNode();
    node.setExecutionContext(
      { value: 42 },
      {
        left: evaluate("context.execution.value"),
        operator: "eq",
        right: 42,
        ifThen: "yes",
      },
      {
        snapshot: { context: { value: 42 }, outputs: {} },
      } as never,
    );

    await expect(node.run()).resolves.toEqual({ nextStep: { stepId: "yes" } });
  });

  it("should use else when a condition fails", async () => {
    const node = new IfNode();

    node.setExecutionContext(
      { value: 41 },
      {
        left: evaluate("context.value"),
        operator: "gte",
        right: 42,
        ifElse: "no",
        ifThen: "yes",
      },
      {
        snapshot: { context: { value: 41 }, outputs: {} },
      } as never,
    );

    await expect(node.run()).resolves.toEqual({ nextStep: { stepId: "no" } });
  });

  it("should return the condition result when no else step is configured", async () => {
    const node = new IfNode();
    node.setExecutionContext(
      { value: 42 },
      {
        left: "$context.value",
        operator: "eq",
        right: 0,
        ifThen: "yes",
      },
      {
        snapshot: { context: { value: 42 }, outputs: {} },
      } as never,
    );

    await expect(node.run()).resolves.toEqual({
      nextStep: NextAction.NEXT,
      output: { conditionMet: false },
    });
  });
});