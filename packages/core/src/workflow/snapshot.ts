import type { Context } from "../context.js";
import type { WorkflowExecutionDefinition } from "./definition.js";

export interface WorkflowSnapshot<TContext extends Context = Context> {
  id: string;
  name: string;
  context: TContext;
  definition: WorkflowExecutionDefinition<TContext>;
  createdAt: Date;
}