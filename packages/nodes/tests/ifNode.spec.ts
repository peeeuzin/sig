import { NextAction } from "@sigworkflow/core";
import { describe, expect, it } from "vitest";
import { IfNode } from "../src/ifNode.js";

describe("IfNode", () => {
  it("evaluates context fields and routes to the matching step", async () => {
    const node = new IfNode();
    const params = {
      field: "$context.value",
      operator: "eq",
      value: 42,
      ifThen: "yes",
    } as const;
    node.setExecutionContext({ value: 42 }, params, {
      snapshot: { context: { value: 42 }, outputs: {} },
    } as never);

    await expect(node.run()).resolves.toEqual({ nextStep: "yes" });
  });

  it("uses else when a condition fails", async () => {
    const node = new IfNode();
    const params = {
      field: "$context.value",
      operator: "gte",
      value: 42,
      ifElse: "no",
      ifThen: "yes",
    } as const;
    node.setExecutionContext({ value: 41 }, params, {
      snapshot: { context: { value: 41 }, outputs: {} },
    } as never);

    await expect(node.run()).resolves.toEqual({ nextStep: "no" });
  });

  it("returns the condition result when no else step is configured", async () => {
    const node = new IfNode();
    const params = {
      field: "$context.value",
      operator: "eq",
      value: 0,
      ifThen: "yes",
    } as const;
    node.setExecutionContext({ value: 42 }, params, {
      snapshot: { context: { value: 42 }, outputs: {} },
    } as never);

    await expect(node.run()).resolves.toEqual({
      nextStep: NextAction.NEXT,
      output: { conditionMet: false },
    });
  });
});