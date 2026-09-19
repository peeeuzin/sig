import type { ExecutionSnapshot } from "../execution/snapshot.js";

export type WorkflowStatus =
	| "pending"
	| "running"
	| "suspended"
	| "completed"
	| "failed"
	| "cancelled";

export type EngineEvent =
	| "step:started"
	| "step:completed"
	| "step:failed"
	| "execution:suspended"
	| "execution:completed"
	| "execution:failed";

export interface EngineOptions {
	adapter: PersistenceAdapter;
	workflows: CompiledWorkflow[];
	concurrency?: number; // quantas execuções processar em paralelo
	pollIntervalMs?: number;
}

export declare class WorkflowEngine {
	constructor(options: EngineOptions);

	/** Cria e persiste uma nova execução (não roda step nenhum ainda) */
	start<TContext = any>(
		workflowName: string,
		initialContext: TContext,
	): Promise<{ executionId: string }>;

	/** Envia um sinal a uma execução suspensa em waitForSignal(name) */
	signal(
		executionId: string,
		signalName: string,
		payload?: unknown,
	): Promise<void>;

	cancel(executionId: string, reason?: string): Promise<void>;

	getExecution(executionId: string): Promise<ExecutionSnapshot>;

	/** Reconstrói o estado via replay dos eventos (útil pra debug/auditoria) */
	replay(executionId: string): Promise<ExecutionSnapshot>;

	/** Inicia o loop de polling que processa execuções pendentes. Retorna função de shutdown. */
	runWorker(): () => Promise<void>;

	on(
		event: EngineEvent,
		handler: (payload: {
			executionId: string;
			stepId?: string;
			error?: Error;
		}) => void,
	): void;
}
