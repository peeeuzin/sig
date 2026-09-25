import type { Context } from "../context.js";
import {
  Execution,
  type ExecutionSnapshot,
  type ExecutionStatus,
  type WorkflowEngine,
} from "../index.js";
import type { WorkflowSnapshot } from "./snapshot.js";

export class Workflow<TContext extends Context = Context> {
  constructor(
    private _snapshot: WorkflowSnapshot<TContext>,
    private _engine: WorkflowEngine,
  ) {}

  get snapshot(): WorkflowSnapshot<TContext> {
    return this._snapshot;
  }

  async spawn<TExecutionContext extends Context>(
    initialContext: TExecutionContext,
  ): Promise<Execution<TExecutionContext>> {
    const firstStepId = Object.keys(this.snapshot.definition)[0];

    const snapshot = (await this._engine.options.db.create({
        model: "workflowExecutions",
        data: {
          workflowId: this.snapshot.id,
          status: "pending" as ExecutionStatus,
          context: initialContext,
          outputs: {},
          currentStep: firstStepId ?? null,
        },
      })) as ExecutionSnapshot<TExecutionContext>;

    return new Execution<TExecutionContext>(snapshot, this, this._engine);
  }

  async start() {}

  async suspend() {}

  async resume() {}
}

export * from "./definition.js";
