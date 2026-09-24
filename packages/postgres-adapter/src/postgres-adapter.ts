/** biome-ignore-all lint/suspicious/noExplicitAny: This is a generic adapter that can be used with any database that supports SQL. */
import type {
  DatabaseAdapter,
  DBTransactionAdapter,
  Model,
  PersistenceOptions,
  Where,
} from "@sigworkflow/core/adapters/database";
import type { Pool, PoolClient } from "pg";

type Queryable = Pick<Pool, "query"> | Pick<PoolClient, "query" | "release">;

function quote(identifier: string): string {
  const parts = identifier.split(".");
  if (!parts.every((part) => /^[A-Za-z_][A-Za-z0-9_$]*$/.test(part))) {
    throw new Error(`Invalid SQL identifier: ${identifier}`);
  }
  return parts.map((part) => `"${part}"`).join(".");
}

function selection(select?: string[]): string {
  return select?.length ? select.map(quote).join(", ") : "*";
}

function whereClause(where?: Where[]): { sql: string; values: unknown[] } {
  if (!where?.length) return { sql: "", values: [] };
  const values: unknown[] = [];
  const clauses = where.map((condition, index) => {
    const field = quote(condition.field);
    const operator = condition.operator ?? "eq";
    const connector = index ? ` ${condition.connector ?? "AND"} ` : "";
    const bind = (value: unknown) => {
      values.push(value);
      return `$${values.length}`;
    };
    const value = condition.value;

    if (value === null) {
      if (operator === "eq") return `${connector + field} IS NULL`;
      if (operator === "ne") return `${connector + field} IS NOT NULL`;
      throw new Error(`Operator "${operator}" cannot be used with null`);
    }

    switch (operator) {
      case "eq":
        return (
          connector +
          field +
          (condition.mode === "insensitive" ? " ILIKE " : " = ") +
          bind(value)
        );
      case "ne":
        return (
          connector +
          field +
          (condition.mode === "insensitive" ? " NOT ILIKE " : " <> ") +
          bind(value)
        );
      case "lt":
        return `${connector + field} < ${bind(value)}`;
      case "lte":
        return `${connector + field} <= ${bind(value)}`;
      case "gt":
        return `${connector + field} > ${bind(value)}`;
      case "gte":
        return `${connector + field} >= ${bind(value)}`;
      case "in":
      case "not_in":
        if (!Array.isArray(value))
          throw new Error(`Operator "${operator}" requires an array value`);
        if (!value.length)
          return connector + (operator === "in" ? "FALSE" : "TRUE");
        return (
          connector +
          field +
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
          field +
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
  const shifted = (sql: string, offset: number) =>
    sql.replace(/\$(\d+)/g, (_, index: string) => `$${Number(index) + offset}`);

  return {
    async create<T extends Record<string, any>, R = T>({
      model,
      data,
      select,
    }: any): Promise<R> {
      const entries = Object.entries(data);
      const result = entries.length
        ? await queryable.query(
            "INSERT INTO " +
              table(model) +
              " (" +
              entries.map(([key]) => quote(key)).join(", ") +
              ") VALUES (" +
              entries.map((_, index) => `$${index + 1}`).join(", ") +
              ") RETURNING " +
              selection(select),
            entries.map(([, value]) => value),
          )
        : await queryable.query(
            "INSERT INTO " +
              table(model) +
              " DEFAULT VALUES RETURNING " +
              selection(select),
          );
      return firstRow(result, "create") as R;
    },
    async findOne<T extends Record<string, any>, R = T>({
      model,
      where,
      select,
    }: any): Promise<R | null> {
      const filter = whereClause(where);
      const result = await queryable.query(
        "SELECT " +
          selection(select) +
          " FROM " +
          table(model) +
          filter.sql +
          " LIMIT 1",
        filter.values,
      );
      return (result.rows[0] as R | undefined) ?? null;
    },
    async findMany<T extends Record<string, any>, R = T>({
      model,
      where,
      select,
      pagination,
    }: any): Promise<R[]> {
      const filter = whereClause(where);
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
          selection(select) +
          " FROM " +
          table(model) +
          filter.sql +
          page,
        values,
      );
      return result.rows as R[];
    },
    async count({ model, where }) {
      const filter = whereClause(where);
      const result = await queryable.query<{ count: string }>(
        `SELECT COUNT(*) AS count FROM ${table(model)} ${filter.sql}`,
        filter.values,
      );
      return Number(firstRow(result, "count").count);
    },
    async update<T extends Record<string, any>, R = T>({
      model,
      where,
      data,
      select,
    }: any): Promise<R> {
      const entries = Object.entries(data);
      if (!entries.length)
        throw new Error("update requires at least one field");
      const filter = whereClause(where);
      const values = entries.map(([, value]) => value).concat(filter.values);
      const assignments = entries
        .map(([key], index) => `${quote(key)} = $${index + 1}`)
        .join(", ");
      const result = await queryable.query(
        "UPDATE " +
          table(model) +
          " SET " +
          assignments +
          shifted(filter.sql, entries.length) +
          " RETURNING " +
          selection(select),
        values,
      );
      return firstRow(result, "update") as R;
    },
    async updateMany({ model, where, update }) {
      const entries = Object.entries(update);
      if (!entries.length) return 0;
      const filter = whereClause(where);
      const values = entries.map(([, value]) => value).concat(filter.values);
      const assignments = entries
        .map(([key], index) => `${quote(key)} = $${index + 1}`)
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
      const filter = whereClause(where);
      await queryable.query(
        `DELETE FROM ${table(model)} ${filter.sql}`,
        filter.values,
      );
    },
  } as DBTransactionAdapter;
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