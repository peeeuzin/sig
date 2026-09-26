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

export function evaluate(field: string): string {
  return `<$${field}>`;
}

export interface NodeRunnable<
  TOutput extends object = Record<string, unknown>,
> {
  run(): Promise<NodeReturn<TOutput>>;
}

export class Node<
  TParams extends Context = Context,
  TOutput extends object = Record<string, unknown>,
  TWorkflowContext extends Context = Context,
  TExecutionContext extends Context = Context,
> implements NodeRunnable<TOutput>
{
  // These fields are defined when the node is executed
  private _context!: TExecutionContext;
  private _params!: TParams;
  private _execution!: Execution<TExecutionContext, TWorkflowContext>;

  /** Context belonging to this workflow definition. */
  protected get workflowContext(): TWorkflowContext {
    return this._execution.workflow.snapshot.context;
  }

  /** Context belonging to this execution instance. */
  protected get context(): TExecutionContext {
    return this._context;
  }

  protected get params(): TParams {
    return this.resolveValue(this._params) as TParams;
  }

  protected get execution(): Execution<TExecutionContext, TWorkflowContext> {
    return this._execution;
  }

  setExecutionContext(
    context: TExecutionContext,
    params: TParams,
    execution: Execution<TExecutionContext, TWorkflowContext>,
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
    // if field does not start with "<$" or does not end with ">",
    // is means that is a string concatenation, so we need to replace all references with their values
    // for example, "Hello <$context.execution.userId>" should be replaced with "Hello 123" if the userId is 123
    if (!field.startsWith("<$") || !field.endsWith(">")) {
      return field.replaceAll(/<\$([\w]+(?:\.[\w]+)*)>/g, (reference) => {
        const value = this.resolveReference(reference);
        return String(value);
      }) as unknown as TReturn;
    }

    return this.resolveReference(field) as TReturn;
  }

  private resolveValue(value: unknown): unknown {
    if (typeof value === "string") return this.evaluate(value);
    if (Array.isArray(value))
      return value.map((item) => this.resolveValue(item));
    if (value && typeof value === "object") {
      return Object.fromEntries(
        Object.entries(value).map(([key, item]) => [
          key,
          this.resolveValue(item),
        ]),
      );
    }
    return value;
  }

  private resolveReference(field: string): unknown {
    const outputs = (this._execution?.outputs ?? this._execution?.snapshot?.outputs ?? {}) as Record<
      string,
      unknown
    >;
    const executionContext = this.context as Record<string, unknown>;
    const workflowContext = (this._execution?.workflow?.snapshot?.context ??
      {}) as Record<string, unknown>;

    const obj: Record<string, unknown> = {
      outputs,
      context: {
        execution: executionContext,
        workflow: workflowContext,
      },
    };

    const parts = field.replace(/<\$|>/g, "").split(".");

    if (parts[0] !== "outputs" && parts[0] !== "context") {
      return parts.reduce<unknown>(
        (current, key) =>
          current && typeof current === "object"
            ? (current as Record<string, unknown>)[key]
            : undefined,
        executionContext,
      );
    }

    return parts.reduce<any>(
      (current, key) =>
        current && typeof current === "object" ? current[key] : undefined,
      obj,
    );
  }
}
