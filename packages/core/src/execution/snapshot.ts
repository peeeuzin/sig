import type { Context } from "../context.js";
import type { ExecutionStatus } from "./index.js";

export interface ExecutionSnapshot<TContext = Context> {
  id: string;
  workflow_id: string;
  status: ExecutionStatus;
  current_step: string;
  outputs: Record<string, unknown>;
  context: TContext;
  created_at: Date;
  updated_at: Date;
}