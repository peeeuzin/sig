import type {
  DatabaseAdapter,
  DatabaseInsert,
  DatabaseSchema,
  DatabaseUpdate,
  DBTransactionAdapter,
  Model,
  PersistenceOptions,
  Where,
} from "@sigworkflow/core/adapters/database";
import type { Pool, PoolClient } from "pg";
import { quote, selection, shifted } from "./sql.js";

type Queryable = Pick<Pool, "query"> | Pick<PoolClient, "query" | "release">;

const bjsonFields: Partial<Record<Model, string[]>> = {
  workflows: ["context", "definition"],
  workflowExecutions: ["context", "outputs"],
  // outbox: ["payload"],
};

export function parseBjsonFields<T extends Record<string, unknown>>(
  model: Model,
  row: T,
  options: PersistenceOptions,
): T {
  const parsed: Record<string, unknown> = { ...row };
  const configuredFields = (
    options as PersistenceOptions & {
      fields?: PersistenceOptions["fields"];
    }
  ).fields?.[model] as Record<string, string> | undefined;

  for (const logicalField of bjsonFields[model] ?? []) {
    const column = configuredFields?.[logicalField] ?? logicalField;
    const value = parsed[logicalField] ?? parsed[column];

    if (typeof value === "string") {
      parsed[logicalField] = JSON.parse(value) as unknown;
    }
  }

  return parsed as T;
}

function toLogicalFields<T extends Record<string, unknown>>(
  model: Model,
  row: T,
  options: PersistenceOptions,
): T {
  const logicalRow: Record<string, unknown> = { ...row };
  const configuredFields = (
    options as PersistenceOptions & {
      fields?: PersistenceOptions["fields"];
    }
  ).fields?.[model] as Record<string, string> | undefined;

  for (const [logicalName, physicalName] of Object.entries(
    configuredFields ?? {},
  )) {
    if (physicalName in logicalRow) {
      logicalRow[logicalName] = logicalRow[physicalName];
      if (physicalName !== logicalName) delete logicalRow[physicalName];
    }
  }

  return logicalRow as T;
}

function whereClause(
  where: Where[] | undefined,
  field: (name: string) => string,
): { sql: string; values: unknown[] } {
  if (!where?.length) return { sql: "", values: [] };
  const values: unknown[] = [];
  const clauses = where.map((condition, index) => {
    const column = field(condition.field);
    const operator = condition.operator ?? "eq";
    const connector = index ? ` ${condition.connector ?? "AND"} ` : "";
    const bind = (value: unknown) => {
      values.push(value);
      return `$${values.length}`;
    };
    const value = condition.value;

    if (value === null) {
      if (operator === "eq") return `${connector + column} IS NULL`;
      if (operator === "ne") return `${connector + column} IS NOT NULL`;
      throw new Error(`Operator "${operator}" cannot be used with null`);
    }

    switch (operator) {
      case "eq":
        return (
          connector +
          column +
          (condition.mode === "insensitive" ? " ILIKE " : " = ") +
          bind(value)
        );
      case "ne":
        return (
          connector +
          column +
          (condition.mode === "insensitive" ? " NOT ILIKE " : " <> ") +
          bind(value)
        );
      case "lt":
        return `${connector + column} < ${bind(value)}`;
      case "lte":
        return `${connector + column} <= ${bind(value)}`;
      case "gt":
        return `${connector + column} > ${bind(value)}`;
      case "gte":
        return `${connector + column} >= ${bind(value)}`;
      case "in":
      case "not_in":
        if (!Array.isArray(value))
          throw new Error(`Operator "${operator}" requires an array value`);
        if (!value.length)
          return connector + (operator === "in" ? "FALSE" : "TRUE");
        return (
          connector +
          column +
          (operator === "in" ? " = ANY(" : " <> ALL(") +
          bind(value) +
          ")"
        );
      case "contains":
      case "starts_with":
      case "ends_with": {
        if (typeof value !== "string")
          throw new Error(`Operator "${operator}" requires a string value`);
        const escaped = value.replace(/[\\%_]/g, "\\$&");
        const pattern =
          operator === "contains"
            ? `%${escaped}%`
            : operator === "starts_with"
              ? `${escaped}%`
              : `%${escaped}`;
        return (
          connector +
          column +
          (condition.mode === "insensitive" ? " ILIKE " : " LIKE ") +
          bind(pattern) +
          " ESCAPE '\\'"
        );
      }
      default:
        throw new Error(`Unknown operator: ${operator}`);
    }
  });
  return { sql: ` WHERE ${clauses.join("")}`, values };
}

function firstRow<R>(result: { rows: R[] }, operation: string): R {
  const row = result.rows[0];
  if (!row) throw new Error(`${operation} did not return a row`);
  return row;
}

export function adapterFor(
  queryable: Queryable,
  options: PersistenceOptions,
): DBTransactionAdapter {
  const table = (model: Model) => {
    const tableName = options.models[model];

    if (!tableName) throw new Error(`Unknown persistence model: ${model}`);

    return quote(tableName);
  };

  const field = (model: Model, logicalField: string) => {
    const configuredFields = (
      options as PersistenceOptions & {
        fields?: PersistenceOptions["fields"];
      }
    ).fields?.[model] as Record<string, string> | undefined;

    return quote(configuredFields?.[logicalField] ?? logicalField);
  };

  const fields = (model: Model, select?: string[]) =>
    select?.length
      ? select
          .map((name) => `${field(model, name)} AS ${quote(name)}`)
          .join(", ")
      : selection();

  const logicalField = (model: Model, name: string) => {
    const configuredFields = (
      options as PersistenceOptions & {
        fields?: PersistenceOptions["fields"];
      }
    ).fields?.[model] as Record<string, string> | undefined;
    return (
      Object.entries(configuredFields ?? {}).find(
        ([, configured]) => configured === name,
      )?.[0] ?? name
    );
  };

  const serialize = (model: Model, name: string, value: unknown) =>
    (bjsonFields[model] ?? []).includes(logicalField(model, name))
      ? JSON.stringify(value)
      : value;

  const entriesFor = (model: Model, entries: [string, unknown][]) =>
    entries.map(
      ([name, value]) =>
        [field(model, name), serialize(model, name, value)] as const,
    );

  return {
    async create<M extends Model>({
      model,
      data,
      select,
    }: {
      model: M;
      data: DatabaseInsert[M];
      select?: string[];
    }): Promise<DatabaseSchema[M]> {
      const entries = entriesFor(
        model,
        Object.entries(data as unknown as Record<string, unknown>),
      );
      const result = entries.length
        ? await queryable.query(
            "INSERT INTO " +
              table(model) +
              " (" +
              entries.map(([key]) => key).join(", ") +
              ") VALUES (" +
              entries.map((_, index) => `$${index + 1}`).join(", ") +
              ") RETURNING " +
              fields(model, select),
            entries.map(([, value]) => value),
          )
        : await queryable.query(
            "INSERT INTO " +
              table(model) +
              " DEFAULT VALUES RETURNING " +
              fields(model, select),
          );

      return parseBjsonFields(
        model,
        toLogicalFields(
          model,
          firstRow(result, "create") as Record<string, unknown>,
          options,
        ),
        options,
      ) as DatabaseSchema[M];
    },
    async findOne<M extends Model>({
      model,
      where,
      select,
    }: {
      model: M;
      where: Where[];
      select?: string[];
    }): Promise<DatabaseSchema[M] | null> {
      const filter = whereClause(where, (name) => field(model, name));
      const result = await queryable.query(
        "SELECT " +
          fields(model, select) +
          " FROM " +
          table(model) +
          filter.sql +
          " LIMIT 1",
        filter.values,
      );
      const row = result.rows[0] as Record<string, unknown> | undefined;
      return row
        ? (parseBjsonFields(
            model,
            toLogicalFields(model, row, options),
            options,
          ) as DatabaseSchema[M])
        : null;
    },
    async findMany<M extends Model>({
      model,
      where,
      select,
      pagination,
    }: {
      model: M;
      where?: Where[];
      select?: string[];
      pagination?: { limit?: number; offset?: number };
    }): Promise<DatabaseSchema[M][]> {
      const filter = whereClause(where, (name) => field(model, name));
      const values = [...filter.values];
      let page = "";
      if (pagination?.limit !== undefined) {
        values.push(pagination.limit);
        page += ` LIMIT $${values.length}`;
      }
      if (pagination?.offset !== undefined) {
        values.push(pagination.offset);
        page += ` OFFSET $${values.length}`;
      }
      const result = await queryable.query(
        "SELECT " +
          fields(model, select) +
          " FROM " +
          table(model) +
          filter.sql +
          page,
        values,
      );
      return result.rows.map((row) =>
        parseBjsonFields(
          model,
          toLogicalFields(model, row as Record<string, unknown>, options),
          options,
        ),
      ) as DatabaseSchema[M][];
    },
    async count({ model, where }) {
      const filter = whereClause(where, (name) => field(model, name));
      const result = await queryable.query<{ count: string }>(
        `SELECT COUNT(*) AS count FROM ${table(model)} ${filter.sql}`,
        filter.values,
      );
      return Number(firstRow(result, "count").count);
    },
    async update<M extends Model>({
      model,
      where,
      data,
      select,
    }: {
      model: M;
      where: Where[];
      data: DatabaseUpdate<M>;
      select?: string[];
    }): Promise<DatabaseSchema[M] | null> {
      const entries = entriesFor(
        model,
        Object.entries(data as unknown as Record<string, unknown>),
      );
      if (!entries.length)
        throw new Error("update requires at least one field");
      const filter = whereClause(where, (name) => field(model, name));
      const values = entries.map(([, value]) => value).concat(filter.values);
      const assignments = entries
        .map(([key], index) => `${key} = $${index + 1}`)
        .join(", ");
      const result = await queryable.query(
        "UPDATE " +
          table(model) +
          " SET " +
          assignments +
          shifted(filter.sql, entries.length) +
          " RETURNING " +
          fields(model, select),
        values,
      );
      const row = result.rows[0] as Record<string, unknown> | undefined;
      return row
        ? (parseBjsonFields(
            model,
            toLogicalFields(model, row, options),
            options,
          ) as DatabaseSchema[M])
        : null;
    },
    async updateMany({ model, where, update }) {
      const entries = entriesFor(
        model,
        Object.entries(update as unknown as Record<string, unknown>),
      );
      if (!entries.length) return 0;
      const filter = whereClause(where, (name) => field(model, name));
      const values = entries.map(([, value]) => value).concat(filter.values);
      const assignments = entries
        .map(([key], index) => `${key} = $${index + 1}`)
        .join(", ");
      const result = await queryable.query(
        "UPDATE " +
          table(model) +
          " SET " +
          assignments +
          shifted(filter.sql, entries.length),
        values,
      );
      return result.rowCount ?? 0;
    },
    async delete({ model, where }) {
      const filter = whereClause(where, (name) => field(model, name));
      await queryable.query(
        `DELETE FROM ${table(model)} ${filter.sql}`,
        filter.values,
      );
    },
  } satisfies DBTransactionAdapter;
}

export function postgres(
  client: Queryable,
): (options: PersistenceOptions) => DatabaseAdapter {
  return (options) => {
    const adapter = adapterFor(client, options);
    return {
      ...adapter,
      async transaction<R>(
        callback: (trx: DBTransactionAdapter) => Promise<R>,
      ) {
        try {
          await client.query("BEGIN");
          const result = await callback(adapterFor(client, options));
          await client.query("COMMIT");
          return result;
        } catch (error) {
          await client.query("ROLLBACK");
          throw error;
        } finally {
          if ("release" in client) client.release();
        }
      },
    };
  };
}