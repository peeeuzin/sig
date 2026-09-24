import type { DatabaseAdapter } from "../adapters/database.js";
import type { MQAdapter } from "../adapters/mq.js";
import type { Context } from "../context.js";
import type { Node } from "../node/index.js";
import { Workflow, type WorkflowDefinition } from "../workflow/index.js";
import type { WorkflowSnapshot } from "../workflow/snapshot.js";
import { runner } from "./runner.js";

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
  db: DatabaseAdapter;
  mq: MQAdapter;
  nodes: Node[];
  worker?: boolean;
}

export class WorkflowEngine {
  private readonly nodes: Map<string, Node>;

  constructor(private options: EngineOptions) {
    this.nodes = new Map(
      options.nodes.map((node) => [node.constructor.name, node]),
    );

    options.mq.spawnWorker(async (job) => await runner(this, job));
  }

  async spawn(
    workflow: WorkflowDefinition,
    initialContext: Context,
  ): Promise<Workflow> {
    const { name, definition } = workflow.build();

    const snapshot: WorkflowSnapshot<Context> = await this.options.db.create({
      model: "workflows",
      data: {
        name: name,
        context: JSON.stringify(initialContext),
        definition: JSON.stringify(definition),
      },
    });

    return new Workflow(snapshot, this.options);
  }

  async poll() {}
}