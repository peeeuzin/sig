import type { Context } from "../context.js";
import type { WorkflowEngine } from "../engine/index.js";
import { NextAction, type Node, type StepReference } from "../index.js";
import type { Workflow } from "../workflow/index.js";
import type { ExecutionSnapshot } from "./snapshot.js";

export * from "./snapshot.js";

export type ExecutionStatus =
  | "pending"
  | "running"
  | "suspended"
  | "completed"
  | "failed"
  | "cancelled";

export class Execution<TContext extends Context = Context> {
  constructor(
    private _snapshot: ExecutionSnapshot<TContext>,
    private _workflow: Workflow,
    private _engine: WorkflowEngine,
  ) {}

  get id(): string {
    return this._snapshot.id;
  }

  get snapshot(): ExecutionSnapshot<TContext> {
    return this._snapshot;
  }

  get outputs(): Record<string, unknown> {
    return this._snapshot.outputs;
  }

  async start(): Promise<void> {
    if (
      this._snapshot.status === "completed" ||
      this._snapshot.status === "failed" ||
      this._snapshot.status === "cancelled"
    ) {
      return;
    }

    const currentStep = this._snapshot.currentStep;
    if (!currentStep) return;

    this._snapshot = await this._engine.options.db.transaction(async (trx) => {
      const execution = await trx.update({
        model: "workflowExecutions",
        where: [{ field: "id", value: this._snapshot.id }],
        data: {
          status: "running",
          updatedAt: new Date(),
        },
      });
      if (!execution) throw new Error(`Execution "${this.id}" not found`);

      await this.publishStepJob(currentStep);

      return execution as ExecutionSnapshot<TContext>;
    });
  }

  async suspend(): Promise<void> {
    if (
      this._snapshot.status === "completed" ||
      this._snapshot.status === "failed"
    ) {
      return;
    }

    const updated = await this._engine.options.db.update({
      model: "workflowExecutions",
      where: [{ field: "id", value: this._snapshot.id }],
      data: {
        status: "suspended",
        updatedAt: new Date(),
      },
    });
    if (!updated) throw new Error(`Execution "${this.id}" not found`);
    this._snapshot = updated as ExecutionSnapshot<TContext>;
  }

  async resume(): Promise<void> {
    if (this._snapshot.status !== "suspended") {
      return;
    }

    const currentStep = this._snapshot.currentStep;
    if (!currentStep) return;

    this._snapshot = await this._engine.options.db.transaction(async (trx) => {
      const execution = await trx.update({
        model: "workflowExecutions",
        where: [{ field: "id", value: this._snapshot.id }],
        data: {
          status: "running",
          updatedAt: new Date(),
        },
      });
      if (!execution) throw new Error(`Execution "${this.id}" not found`);

      await this.publishStepJob(currentStep);

      return execution as ExecutionSnapshot<TContext>;
    });
  }

  private async publishStepJob(stepId: string): Promise<void> {
    await this._engine.options.mq.publish("execute-step", {
      executionId: this._snapshot.id,
      stepId,
      workflowId: this._snapshot.workflowId,
    });
  }

  async execute(): Promise<void> {
    if (
      this._snapshot.status === "completed" ||
      this._snapshot.status === "failed" ||
      this._snapshot.status === "cancelled" ||
      this._snapshot.status === "suspended"
    ) {
      return;
    }

    const currentStepId = this._snapshot.currentStep;
    if (!currentStepId) {
      await this.complete();
      return;
    }

    const step = this._workflow.snapshot.definition[currentStepId];

    if (!step) {
      await this.fail(
        `Step "${currentStepId}" not found in workflow definition`,
      );
      return;
    }

    const nodeId = step.execute.id;

    const baseNode = this._engine.getNode(nodeId);

    if (!baseNode) {
      await this.fail(`Cannot find node for step "${step.name}" (${nodeId})`);
      return;
    }

    const nodeInstance: Node = Object.create(baseNode);
    nodeInstance.setExecutionContext(
      this._snapshot.context,
      step.execute.params,
      this,
    );

    await this._engine.options.db.transaction(async (trx) => {
      this._engine.listeners.get("step:started")?.forEach((callback) => {
        callback({
          executionId: this._snapshot.id,
          stepId: currentStepId,
          workflowId: this._snapshot.workflowId,
          context: this._snapshot.context,
          outputs: this._snapshot.outputs,
        });
      });

      const { nextStep, output } = await nodeInstance.run();

      this._engine.listeners.get("step:completed")?.forEach((callback) => {
        callback({
          executionId: this._snapshot.id,
          stepId: currentStepId,
          workflowId: this._snapshot.workflowId,
          context: this._snapshot.context,
          outputs: this._snapshot.outputs,
        });
      });

      if (output) this.appendOutput(currentStepId, output);
      const nextStepId = this.nextStepId(nextStep || step.next);

      const updated = await trx.update({
        model: "workflowExecutions",
        where: [{ field: "id", value: this._snapshot.id }],
        data: {
          currentStep: nextStepId,
          context: this._snapshot.context,
          outputs: this._snapshot.outputs,
          updatedAt: new Date(),
        },
      });
      if (!updated) throw new Error(`Execution "${this.id}" not found`);
      this._snapshot = updated as ExecutionSnapshot<TContext>;

      if (nextStepId) {
        await this.publishStepJob(nextStepId);
      } else {
        await this.complete();
      }
    });
  }

  private appendOutput<T>(key: string, value: T) {
    if (!this._snapshot.outputs) {
      this._snapshot.outputs = {};
    }
    this._snapshot.outputs[key] = value;
  }

  private nextStepId(nextStepReference: StepReference): string | null {
    if (typeof nextStepReference === "object" && "stepId" in nextStepReference)
      return nextStepReference.stepId;

    if (nextStepReference === NextAction.NEXT) {
      const currentStep = this._snapshot.currentStep;
      if (!currentStep) return null;
      const definition = this._workflow.snapshot.definition;

      const stepIds = Object.keys(definition);
      const currentStepIndex = stepIds.indexOf(currentStep);

      if (currentStepIndex === -1) return null;

      const nextStepIndex = currentStepIndex + 1;

      if (nextStepIndex < stepIds.length) {
        return stepIds[nextStepIndex] ?? null;
      }
    }

    return null;
  }

  private async complete(): Promise<void> {
    const updated = await this._engine.options.db.update({
      model: "workflowExecutions",
      where: [{ field: "id", value: this._snapshot.id }],
      data: {
        currentStep: null,
        context: this._snapshot.context,
        outputs: this._snapshot.outputs,
        status: "completed",
        updatedAt: new Date(),
      },
    });
    if (!updated) throw new Error(`Execution "${this.id}" not found`);

    this._engine.listeners.get("execution:completed")?.forEach((callback) => {
      callback({
        executionId: this._snapshot.id,
        workflowId: this._snapshot.workflowId,
        context: this._snapshot.context,
        outputs: this._snapshot.outputs,
      });
    });

    this._snapshot = updated as ExecutionSnapshot<TContext>;
  }

  private async fail(_error: string): Promise<void> {
    this._snapshot.status = "failed";

    const updated = await this._engine.options.db.update({
      model: "workflowExecutions",
      where: [{ field: "id", value: this._snapshot.id }],
      data: {
        status: "failed",
        updatedAt: new Date(),
      },
    });
    if (!updated) throw new Error(`Execution "${this.id}" not found`);
    this._snapshot = updated as ExecutionSnapshot<TContext>;
  }
}