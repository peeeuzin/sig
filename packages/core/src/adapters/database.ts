import type { Context } from "../context.js";
import type { WorkflowStatus } from "../engine/index.js";
import type { WorkflowExecutionDefinition } from "../workflow/definition.js";

export type DatabaseSchema = {
  workflows: {
    id: string;
    name: string;
    context: Context;
    definition: WorkflowExecutionDefinition;
    createdAt: Date;
  };
  workflowExecutions: {
    id: string;
    workflowId: string;
    status: WorkflowStatus;
    currentStep: string | null;
    context: Context;
    outputs: Record<string, unknown>;
    createdAt: Date;
    updatedAt: Date;
  };
  // outbox: {
  //   id: number;
  //   executionId: string;
  //   eventType: string;
  //   payload: Record<string, unknown>;
  //   status: "pending" | "sent" | "failed";
  //   attempts: number;
  //   createdAt: Date;
  //   processedAt: Date | null;
  // };
};

export type Model = keyof DatabaseSchema;

/** Fields omitted here are supplied by the database defaults. */
export type DatabaseInsert = {
  workflows: Pick<DatabaseSchema["workflows"], "name"> &
    Partial<Omit<DatabaseSchema["workflows"], "name">>;
  workflowExecutions: Pick<
    DatabaseSchema["workflowExecutions"],
    "workflowId" | "status"
  > &
    Partial<
      Omit<DatabaseSchema["workflowExecutions"], "workflowId" | "status">
    >;
  // outbox: Pick<
  //   DatabaseSchema["outbox"],
  //   "executionId" | "eventType" | "payload"
  // > &
  //   Partial<
  //     Omit<
  //       DatabaseSchema["outbox"],
  //       "executionId" | "eventType" | "payload"
  //     >
  //   >;
};

export type DatabaseUpdate<M extends Model> = Partial<
  Omit<DatabaseSchema[M], "id">
>;

export type PersistenceOptions = {
  models: Record<Model, string>;
  fields: {
    [K in Model]: Record<keyof DatabaseSchema[K], string>;
  };
};

export type Pagination = {
  limit?: number;
  offset?: number;
};

export type WhereOperator =
  | "eq"
  | "ne"
  | "lt"
  | "lte"
  | "gt"
  | "gte"
  | "in"
  | "not_in"
  | "contains"
  | "starts_with"
  | "ends_with";

export type Where = {
  operator?: WhereOperator | undefined;
  value: string | number | boolean | string[] | number[] | Date | null;
  field: string;
  connector?: ("AND" | "OR") | undefined;
  mode?: "sensitive" | "insensitive" | undefined;
};

export type DBTransactionAdapter = Omit<DatabaseAdapter, "transaction">;

export interface DatabaseAdapter {
  create: <M extends Model>(data: {
    model: M;
    data: DatabaseInsert[M];
    select?: string[];
  }) => Promise<DatabaseSchema[M]>;
  findOne: <M extends Model>(data: {
    model: M;
    where: Where[];
    select?: string[];
  }) => Promise<DatabaseSchema[M] | null>;
  findMany: <M extends Model>(data: {
    model: M;
    where?: Where[];
    select?: string[];
    pagination?: Pagination;
  }) => Promise<DatabaseSchema[M][]>;
  count: (data: { model: Model; where?: Where[] }) => Promise<number>;
  update: <M extends Model>(data: {
    model: M;
    where: Where[];
    data: DatabaseUpdate<M>;
    select?: string[];
  }) => Promise<DatabaseSchema[M] | null>;
  updateMany: <M extends Model>(data: {
    model: M;
    where: Where[];
    update: DatabaseUpdate<M>;
  }) => Promise<number>;
  delete: (data: { model: Model; where: Where[] }) => Promise<void>;

  transaction: <R>(
    callback: (trx: DBTransactionAdapter) => Promise<R>,
  ) => Promise<R>;
}

export function databaseAdapter(
  adapter: (p: PersistenceOptions) => DatabaseAdapter,
  options: PersistenceOptions = {
    models: {
      workflows: "workflows",
      workflowExecutions: "workflow_executions",
      // outbox: "outbox",
    },
    fields: {
      workflows: {
        id: "id",
        context: "context",
        name: "name",
        definition: "definition",
        createdAt: "created_at",
      },
      workflowExecutions: {
        id: "id",
        workflowId: "workflow_id",
        status: "status",
        currentStep: "current_step",
        context: "context",
        outputs: "outputs",
        createdAt: "created_at",
        updatedAt: "updated_at",
      },
      // outbox: {
      //   id: "id",
      //   executionId: "execution_id",
      //   eventType: "event_type",
      //   payload: "payload",
      //   status: "status",
      //   attempts: "attempts",
      //   createdAt: "created_at",
      //   processedAt: "processed_at",
      // },
    },
  },
): DatabaseAdapter {
  return adapter(options);
}