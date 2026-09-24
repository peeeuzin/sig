import { randomUUID } from "node:crypto";
import type { Context } from "../context.js";
import type { Execution } from "../execution/index.js";

export interface NodeDefinition<TParams extends Context = Context> {
  id: string;
  params: TParams;
}

export class Node<
  TParams extends Context = Context,
  TContext extends Context = Context,
> {
  // These fields are defined when the node is executed
  private _context!: TContext;
  private _params!: TParams;
  private _execution!: Execution<TContext>;

  protected get context(): TContext {
    return this._context;
  }

  protected get params(): TParams {
    return this._params;
  }

  execute(params: TParams): NodeDefinition<TParams> {
    return {
      params,
      id: randomUUID().toString(),
    };
  }

  async run(): Promise<void> {}

  protected async setStep(stepId: string): Promise<void> {
    // await this._execution.setStep(stepId);
  }

  protected evaluate(field: string): any {
    this._execution.snapshot.outputs;
  }
}