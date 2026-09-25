export type MessageQueueOptions = {
  jobQueueName: string;
  concurrency?: number;
};

export type JobData = {
  executionId: string;
  stepId?: string;
  workflowId?: string;
  attempt?: number;
  [key: string]: any;
};

export interface MQAdapter {
  publish(topic: string, message: JobData | any): Promise<void>;
  spawnWorker(runner: (job: any) => Promise<void>): any;
}

export function mqAdapter(
  adapter: (p: MessageQueueOptions) => MQAdapter,
  options: MessageQueueOptions = {
    jobQueueName: "sig-job-queue",
    concurrency: 5,
  },
): MQAdapter {
  return adapter(options);
}
