import { Node } from "@sigworkflow/core";

export type Operator = "eq" | "neq" | "gt" | "lt" | "gte" | "lte";

export type IfNodeParams = {
  field: string;
  operator: Operator;
  value: any;
  ifThen: string;
  ifElse?: string;
};

export type IfNodeOutput = {
  conditionMet: boolean;
};

export class IfNode extends Node<IfNodeParams, IfNodeOutput> {
  async run() {
    const evaluatedValue = this.evaluate(this.params.field);

    const conditionMet = evaluateCondition(
      evaluatedValue,
      this.params.operator,
      this.params.value,
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