import { describe, expect, it } from "vitest";
import { bullmq } from "../packages/bullmq-adapter/src";
import {
  NextAction,
  WorkflowDefinition,
  WorkflowEngine,
} from "../packages/core/src";
import { databaseAdapter } from "../packages/core/src/adapters/database";
import { mqAdapter } from "../packages/core/src/adapters/mq";
import { IfNode } from "../packages/nodes/src";
import { postgres } from "../packages/postgres-adapter/src";
import { pool } from "./connections/database";
import { redis } from "./connections/mq";
import { TestNode } from "./fixture/testNode";

describe("sig", () => {
  it("should run a workflow with postgres and bullmq", async () => {
    const engine = new WorkflowEngine({
      db: databaseAdapter(postgres(pool)),
      mq: mqAdapter(
        bullmq({
          connection: redis,
        }),
      ),
      nodes: [new IfNode(), new TestNode()],
    });

    const workflow = await engine.spawn(
      WorkflowDefinition.define("test")
        .step("if", {
          name: "If Node",
          execute: new IfNode().execute({
            field: "$context.value",
            operator: "eq",
            value: 42,
            ifThen: "true-step",
            ifElse: "false-step",
          }),
        })
        .step("true-step", {
          name: "True Step",
          execute: new TestNode().execute({
            const: "true",
          }),
          next: NextAction.END,
        })
        .step("false-step", {
          name: "False Step",
          execute: new TestNode().execute({
            const: "false",
          }),
          next: NextAction.END,
        }),
      {},
    );

    const execution = await workflow.spawn({
      value: 42,
    });

    await execution.start();

    const outputs = await new Promise((resolve) =>
      engine.on("execution:completed", (data) => {
        resolve(data.outputs);
      }),
    );

    expect(outputs).toEqual({
      "true-step": {
        result: "true",
      },
    });
  });
});