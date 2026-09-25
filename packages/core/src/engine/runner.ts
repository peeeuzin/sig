import type { JobData } from "../adapters/mq.js";
import { Execution } from "../execution/index.js";
import { Workflow } from "../workflow/index.js";
import type { WorkflowEngine } from "./index.js";

export async function runner(
  instance: WorkflowEngine,
  job: JobData,
): Promise<void> {
  const executionId = job?.executionId;
  if (!executionId) {
    return;
  }

  const executionSnapshot = await instance.options.db.findOne({
    model: "workflowExecutions",
    where: [{ field: "id", value: executionId }],
  });

  if (!executionSnapshot) return;

  if (
    ["completed", "failed", "cancelled", "suspended"].includes(
      executionSnapshot.status,
    )
  )
    return;

  const workflowSnapshot = await instance.options.db.findOne({
    model: "workflows",
    where: [{ field: "id", value: executionSnapshot.workflowId }],
  });

  if (!workflowSnapshot) return;

  const workflow = new Workflow(workflowSnapshot, instance);
  const execution = new Execution(executionSnapshot, workflow, instance);

  await execution.execute();
}