import { Node } from "@sigworkflow/core";

export type Operator = "eq" | "neq" | "gt" | "lt" | "gte" | "lte";

export type IfNodeParams = {
  field: string;
  operator: Operator;
  value: any;
  then: string;
  else?: string;
};

export class IfNode extends Node<IfNodeParams> {
  async run(): Promise<void> {
    const evaluatedValue = this.evaluate(this.params.field);

    const conditionMet = evaluateCondition(
      evaluatedValue,
      this.params.operator,
      this.params.value,
    );

    if (conditionMet) {
      await this.setStep(this.params.then);
    } else if (this.params.else) {
      await this.setStep(this.params.else);
    }
  }
}

function evaluateCondition(
  fieldValue: any,
  operator: Operator,
  value: any,
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