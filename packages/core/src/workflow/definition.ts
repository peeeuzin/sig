import type { Context } from "../context.js";
import type { NodeDefinition } from "../node/index.js";

export interface WorkflowExecutionDefinition<
  TContext extends Context = Context,
> {
  id: string;
  name: string;
  execute: NodeDefinition<TContext>;
  retry: RetryPolicy | undefined;
}

export class WorkflowDefinition<TContext extends Context = Context> {
  private name: string;
  private steps: Array<StepDefinition<TContext>> = [];

  constructor(name: string) {
    this.name = name;
  }

  static define<TContext extends Context = Context>(
    name: string,
  ): WorkflowDefinition<TContext> {
    return new this(name);
  }

  step(id: string, def: Omit<StepDefinition<TContext>, "id">): this {
    this.steps.push({ ...def, id });

    return this;
  }

  build() {
    return {
      name: this.name,
      definition: this.steps.map((step) => ({
        id: step.id,
        name: step.name,
        execute: step.execute,
        retry: step.retry,
      })) satisfies WorkflowExecutionDefinition<TContext>[],
    };
  }
}

export interface RetryPolicy {
  maxAttempts: number;
  delayMs: number;
}

export interface StepDefinition<TParams extends Context = Context> {
  id: string;
  name: string;
  retry?: RetryPolicy;
  execute: NodeDefinition<TParams>;
}