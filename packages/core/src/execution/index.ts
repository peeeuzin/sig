export interface ExecutionEvent {
	seq: number;
	type: string;
	payload: unknown;
	createdAt: Date;
}
