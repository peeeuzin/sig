import type {
  MessageQueueOptions,
  MQAdapter,
} from "@sigworkflow/core/adapters/mq";
import { type ConnectionOptions, Queue, Worker } from "bullmq";

export type BullMQAdapterOptions = {
  connection: ConnectionOptions;
};

export function bullmq(
  bullmqOptions: BullMQAdapterOptions,
): (adapterOptions: MessageQueueOptions) => MQAdapter {
  return (adapterOptions: MessageQueueOptions) => {
    const queue = new Queue(adapterOptions.jobQueueName, {
      connection: bullmqOptions.connection,
    });

    return {
      publish: async (topic: string, message: any) => {
        await queue.add(topic, message, {});
      },

      spawnWorker: (runner) => {
        new Worker(
          adapterOptions.jobQueueName,
          async (job) => {
            await runner(job.data);
          },
          {
            connection: bullmqOptions.connection,
            concurrency: adapterOptions.concurrency || 1,
          },
        );
      },
    };
  };
}