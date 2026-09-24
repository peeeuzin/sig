import type { Context, ExecutionSnapshot } from "../index.js";
import type { WorkflowSnapshot } from "../workflow/snapshot.js";

export * from "./snapshot.js";

export type ExecutionStatus =
  | "pending"
  | "running"
  | "suspended"
  | "completed"
  | "failed"
  | "cancelled";

export class Execution<TContext extends Context = Context> {
  constructor(
    private _snapshot: ExecutionSnapshot<TContext>,
    private _workflowSnapshot: WorkflowSnapshot,
  ) {}

  get snapshot(): ExecutionSnapshot<TContext> {
    return this._snapshot;
  }

  private get workflowSnapshot(): WorkflowSnapshot {
    return this._workflowSnapshot;
  }

  // async start() {}

  // async suspend() {}

  // async resume() {}

  async execute() {
    // const stepSnapshot =
    // this.workflowSnapshot.definition[this.snapshot.current_step];
  }
}