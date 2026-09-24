export type MessageQueueOptions = {
  jobQueueName: string;
  concurrency?: number;
};

export type JobData = {};

export interface MQAdapter {
  publish(topic: string, message: any): Promise<void>;
  spawnWorker(runner: (job: any) => Promise<void>): void;
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