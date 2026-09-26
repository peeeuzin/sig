import { describe, expect, it } from "vitest";
import { evaluate, NextAction, Node } from "../src";

class EchoNode extends Node<{ value: string }, { value: string }> {
  async run() {
    return this.next({ value: this.params.value });
  }
}

describe("node", () => {
  it("should execute a node", async () => {
    const definition = new EchoNode().execute({ value: "hello" });

    expect(definition).toEqual({
      id: "EchoNode",
      params: { value: "hello" },
    });

    const node = new EchoNode();
    node.setExecutionContext({ userId: "123" }, definition.params, {} as any);

    const result = await node.run();

    expect(result).toEqual({
      nextStep: NextAction.NEXT,
      output: { value: "hello" },
    });
  });

  it("should evaluate a field from context", async () => {
    const definition = new EchoNode().execute({
      value: evaluate("context.execution.userId"),
    });

    expect(definition).toEqual({
      id: "EchoNode",
      params: { value: "<$context.execution.userId>" },
    });

    const node = new EchoNode();
    node.setExecutionContext({ userId: "123" }, definition.params, {} as any);

    const result = await node.run();

    expect(result).toEqual({
      nextStep: NextAction.NEXT,
      output: { value: "123" },
    });
  });

  it("should evaluate a field from outputs", async () => {
    const definition = new EchoNode().execute({
      value: evaluate("outputs.previousStep.result"),
    });

    expect(definition).toEqual({
      id: "EchoNode",
      params: { value: "<$outputs.previousStep.result>" },
    });

    const node = new EchoNode();
    node.setExecutionContext({}, definition.params, {
      outputs: {
        previousStep: {
          result: "outputValue",
        },
      },
    } as any);

    const result = await node.run();

    expect(result).toEqual({
      nextStep: NextAction.NEXT,
      output: { value: "outputValue" },
    });
  });

  it("should evaluate a field from context and outputs", async () => {
    const definition = new EchoNode().execute({
      value: `Hello ${evaluate("context.execution.userId")}, your previous result was ${evaluate("outputs.previousStep.result")}`,
    });

    expect(definition).toEqual({
      id: "EchoNode",
      params: {
        value:
          "Hello <$context.execution.userId>, your previous result was <$outputs.previousStep.result>",
      },
    });

    const node = new EchoNode();
    node.setExecutionContext({ userId: "123" }, definition.params, {
      outputs: {
        previousStep: {
          result: "outputValue",
        },
      },
    } as any);

    const result = await node.run();

    expect(result).toEqual({
      nextStep: NextAction.NEXT,
      output: { value: "Hello 123, your previous result was outputValue" },
    });
  });

  it("should evaluate others types of fields from context and outputs", async () => {
    const definition = new EchoNode().execute({
      value: `Hello ${evaluate("context.execution.userId")}, your previous result was ${evaluate("outputs.previousStep.result")}`,
    });

    expect(definition).toEqual({
      id: "EchoNode",
      params: {
        value:
          "Hello <$context.execution.userId>, your previous result was <$outputs.previousStep.result>",
      },
    });

    const node = new EchoNode();
    node.setExecutionContext({ userId: 123 }, definition.params, {
      outputs: {
        previousStep: {
          result: true,
        },
      },
    } as any);

    const result = await node.run();

    expect(result).toEqual({
      nextStep: NextAction.NEXT,
      output: { value: "Hello 123, your previous result was true" },
    });
  });
});