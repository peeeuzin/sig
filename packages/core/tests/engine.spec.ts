import { postgres } from "@sigworkflow/postgres-adapter";
import { describe, test } from "vitest";
import { databaseAdapter } from "../dist/adapters/database";
import { Node, Workflow, WorkflowDefinition, WorkflowEngine } from "../src";
import { pool } from "./database";

class TestNode extends Node<{ foo: string }> {
  async run(): Promise<void> {
    console.log("Running test node");
  }
}

describe("engine", () => {
  test("should run engine tests", async () => {
    const engine = new WorkflowEngine({
      db: databaseAdapter(postgres(pool)),
      nodes: [new TestNode()],
    });

    const workflow = await engine.spawn(
      new WorkflowDefinition("test-workflow").step("step1", {
        name: "Step 1",
        execute: new TestNode().execute({ foo: "bar" }),
      }),
      {},
    );

    const execution = await workflow.spawn({
      a: 1,
    });

    console.log("Execution snapshot:", execution);
  });
});