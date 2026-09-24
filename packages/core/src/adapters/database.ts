export type Model =
  | "workflows"
  | "workflowExecutions"
  | "executionEvents"
  | "stepExecutions"
  | "outbox";

export type PersistenceOptions = {
  models: Record<Model, string>;
};

export type Pagination = {
  limit?: number;
  offset?: number;
};

export const whereOperators = [
  "eq",
  "ne",
  "lt",
  "lte",
  "gt",
  "gte",
  "in",
  "not_in",
  "contains",
  "starts_with",
  "ends_with",
] as const;

export type WhereOperator = (typeof whereOperators)[number];

export type Where = {
  operator?: WhereOperator | undefined;
  value: string | number | boolean | string[] | number[] | Date | null;
  field: string;
  connector?: ("AND" | "OR") | undefined;
  mode?: "sensitive" | "insensitive" | undefined;
};

export type DBTransactionAdapter = Omit<DatabaseAdapter, "transaction">;

export interface DatabaseAdapter {
  create: <T extends Record<string, any>, R = T>(data: {
    model: Model;
    data: Omit<T, "id">;
    select?: string[];
  }) => Promise<R>;
  findOne: <T extends Record<string, any>, R = T>(data: {
    model: Model;
    where: Where[];
    select?: string[];
  }) => Promise<R | null>;
  findMany: <T extends Record<string, any>, R = T>(data: {
    model: Model;
    where?: Where[];
    select?: string[];
    pagination?: Pagination;
  }) => Promise<R[]>;
  count: (data: { model: Model; where?: Where[] }) => Promise<number>;
  update: <T extends Record<string, any>, R = T>(data: {
    model: Model;
    where: Where[];
    data: Partial<Omit<T, "id">>;
    select?: string[];
  }) => Promise<R>;
  updateMany: (data: {
    model: Model;
    where: Where[];
    update: Record<string, any>;
  }) => Promise<number>;
  delete: <_T>(data: { model: Model; where: Where[] }) => Promise<void>;

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
      executionEvents: "execution_events",
      stepExecutions: "step_executions",
      outbox: "outbox",
    },
  },
): DatabaseAdapter {
  return adapter(options);
}