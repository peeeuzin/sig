import type { WorkflowStatus } from "../engine/index.js";

export interface ExecutionSnapshot<TContext = any> {
	id: string;
	workflowName: string;
	workflowVersion: number;
	status: WorkflowStatus;
	currentStep: string | null;
	context: TContext;
	version: number;
}
