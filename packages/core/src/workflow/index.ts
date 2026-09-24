import type { Context } from "../context.js";
import {
  type EngineOptions,
  Execution,
  type ExecutionSnapshot,
  type ExecutionStatus,
} from "../index.js";
import type { WorkflowSnapshot } from "./snapshot.js";

export class Workflow<TContext extends Context = Context> {
  constructor(
    private snapshot: WorkflowSnapshot<TContext>,
    private options: EngineOptions,
  ) {}

  async spawn<TExecutionContext extends Context>(
    initialContext: TExecutionContext,
  ): Promise<Execution<TExecutionContext>> {
    const snapshot: ExecutionSnapshot<TExecutionContext> =
      await this.options.db.create({
        model: "workflowExecutions",
        data: {
          workflow_id: this.snapshot.id,
          status: "suspended" as ExecutionStatus,
          context: initialContext,
          current_step: this.snapshot.definition[0]?.id ?? null,
        },
      });

    return new Execution<TExecutionContext>(snapshot);
  }

  async start() {}

  async suspend() {}

  async resume() {}
}

export * from "./definition.js";