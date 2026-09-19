import type { ExecutionEvent } from "../execution/index.js";
import type { ExecutionSnapshot } from "../execution/snapshot.js";

export interface DatabaseAdapter {
	createExecution(input: {
		workflowName: string;
		workflowVersion: number;
		initialContext: unknown;
	}): Promise<string>;

	appendEvent(
		executionId: string,
		event: Omit<ExecutionEvent, "seq" | "createdAt">,
	): Promise<void>;

	loadExecution(executionId: string): Promise<ExecutionSnapshot | null>;

	loadEvents(executionId: string, sinceSeq?: number): Promise<ExecutionEvent[]>;

	/** Falha silenciosamente (retorna false) se expectedVersion não bater — quem chama decide retry */
	updateExecutionState(
		executionId: string,
		patch: Partial<
			Pick<ExecutionSnapshot, "status" | "currentStep" | "context">
		>,
		expectedVersion: number,
	): Promise<boolean>;

	/** Pra workers fazerem polling de trabalho pendente */
	claimPendingExecutions(limit: number): Promise<ExecutionSnapshot[]>;
}
