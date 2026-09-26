import { type BasicTypes, type Context, Node } from "@sigworkflow/core";

export type Operator = "eq" | "neq" | "gt" | "lt" | "gte" | "lte";

export type IfNodeValue = BasicTypes | Context | Context[];

export type IfNodeParams = {
  left: IfNodeValue;
  operator: Operator;
  right: IfNodeValue;
  ifThen: string;
  ifElse?: string;
};

export type IfNodeOutput = {
  conditionMet: boolean;
};

export class IfNode extends Node<IfNodeParams, IfNodeOutput> {
  async run() {
    const conditionMet = evaluateCondition(
      this.params.left,
      this.params.operator,
      this.params.right,
    );

    if (conditionMet) {
      return this.goTo(this.params.ifThen);
    } else if (this.params.ifElse) {
      return this.goTo(this.params.ifElse);
    }

    return this.next({ conditionMet });
  }
}

function evaluateCondition<V>(
  fieldValue: V,
  operator: Operator,
  value: V,
): boolean {
  switch (operator) {
    case "eq":
      return fieldValue === value;
    case "neq":
      return fieldValue !== value;
    case "gt":
      return fieldValue > value;
    case "lt":
      return fieldValue < value;
    case "gte":
      return fieldValue >= value;
    case "lte":
      return fieldValue <= value;
    default:
      throw new Error(`Unsupported operator: ${operator}`);
  }
}