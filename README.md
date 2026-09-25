# Sig (WIP)
A Typescript workflow engine

## Installation

```bash
npm install @sigworkflow/sig
# or
yarn add @sigworkflow/sig
# or
pnpm add @sigworkflow/sig
# or
bun add @sigworkflow/sig
```

## Example

```ts
import { WorkflowEngine, databaseAdapter, WorkflowDefinition } from '@sigworkflow/sig';
import { postgres } from '@sigworkflow/postgres-adapter';
import { bullmq } from '@sigworkflow/bullmq-adapter';

const engine = new WorkflowEngine({
  db: databaseAdapter(postgres(pool)), // your database connection
  mq: mqAdapter(bullmq(connection)), // your message queue connection
  nodes: [new AI(), new Approval(), new IfNode(), new Blog()] // your workflow nodes
});

// create new workflow
const workflow = await engine.spawn(
  new WorkflowDefinition("marketing-workflow")
    .step("create-blog-post", {
      name: "Create Blog Post",
      execute: new AI().execute({ model: "claude-sonnet-4-5", input: "write a blog post about AI" })
    })
    .step("approve-blog-post", {
      name: "Wait for Approval",
      execute: new Approval().execute({ approver: "manager" })
    })
    .step("publish-blog-post", {
      name: "Publish Blog Post",
      execute: new IfNode().execute({
        field: "$approve-blog-post.approved",
        condition: "equals",
        value: true,
        then: "post-blog",
        else: "reject-blog"
      })
    })
    .step("post-blog", {
      name: "Post Blog",
      execute: new Blog().execute({ 
        create: {
          title: "$create-blog-post.title", content: "$create-blog-post.content"
        }
      })
    })
);

// create execution
const execution = await workflow.spawn({
  userId: "user-123",
});

```