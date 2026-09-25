import type { Context } from "../context.js";
import type { Execution } from "../execution/index.js";

export interface NodeDefinition<TParams extends Context = Context> {
  id: string;
  params: TParams;
}

export enum NextAction {
  NEXT = "NEXT",
  END = "END",
}

export type StepReference =
  | {
      stepId: string;
    }
  | NextAction;

export type NodeReturn<TOutput extends object = Record<string, unknown>> = {
  nextStep?: StepReference;
  output?: TOutput;
};

export interface NodeRunnable<
  TOutput extends object = Record<string, unknown>,
> {
  run(): Promise<NodeReturn<TOutput>>;
}

export class Node<
  TParams extends Context = Context,
  TOutput extends object = Record<string, unknown>,
  TContext extends Context = Context,
> implements NodeRunnable<TOutput>
{
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

  protected get execution(): Execution<TContext> {
    return this._execution;
  }

  setExecutionContext(
    context: TContext,
    params: TParams,
    execution: Execution<TContext>,
  ): void {
    this._context = context;
    this._params = params;
    this._execution = execution;
  }

  execute(params: TParams): NodeDefinition<TParams> {
    return {
      params,
      id: this.constructor.name,
    };
  }

  async run(): Promise<NodeReturn<TOutput>> {
    return {};
  }

  protected next(output?: TOutput): NodeReturn<TOutput> {
    return {
      nextStep: NextAction.NEXT,
      ...(output !== undefined && { output }),
    };
  }

  protected end(output?: TOutput): NodeReturn<TOutput> {
    return {
      nextStep: NextAction.END,
      ...(output !== undefined && { output }),
    };
  }

  protected goTo(stepId: string, output?: TOutput): NodeReturn<TOutput> {
    return {
      nextStep: {
        stepId,
      },
      ...(output !== undefined && { output }),
    };
  }

  protected evaluate<TReturn = unknown>(field: string): TReturn {
    if (!field.startsWith("$")) return field as unknown as TReturn;

    const outputs = (this._execution?.snapshot?.outputs ?? {}) as Record<
      string,
      unknown
    >;
    const context = (this._execution?.snapshot?.context ?? {}) as Record<
      string,
      unknown
    >;

    const obj: Record<string, unknown> = {
      output: outputs,
      context,
    };

    const parts = field.replace(/^\$/, "").split(".");

    return parts.reduce<any>(
      (current, key) =>
        current && typeof current === "object" ? current[key] : undefined,
      obj,
    ) as TReturn;
  }
}