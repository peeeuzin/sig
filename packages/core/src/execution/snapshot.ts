import type { Context } from "../context.js";
import type { ExecutionStatus } from "./index.js";

export interface ExecutionSnapshot<TContext = Context> {
  id: string;
  workflowId: string;
  status: ExecutionStatus;
  currentStep: string | null;
  outputs: Record<string, unknown>;
  context: TContext;
  createdAt: Date;
  updatedAt: Date;
}