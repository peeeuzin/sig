import {
  type BasicTypes,
  Node,
  type NodeReturn,
} from "../../packages/core/src";

export type TestNodeParams = {
  const: BasicTypes;
};

export type TestNodeOutput = {
  result: BasicTypes;
};

export class TestNode extends Node<TestNodeParams, TestNodeOutput> {
  async run(): Promise<NodeReturn<TestNodeOutput>> {
    return {
      output: {
        result: this.params.const,
      },
    };
  }
}