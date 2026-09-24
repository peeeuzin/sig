import { readFileSync } from "node:fs";
import path from "node:path";
import { PostgreSqlContainer } from "@testcontainers/postgresql";
import { Pool } from "pg";
import type { TestProject } from "vitest/node";

const schemaSqlPath = path.join(__dirname, "fixture", "schema.sql");

export default async function setup({ provide }: TestProject) {
  const postgresContainer = await new PostgreSqlContainer(
    "postgres:17",
  ).start();
  const url = postgresContainer.getConnectionUri();
  const pool = new Pool({ connectionString: url });

  await pool.query(readFileSync(schemaSqlPath, "utf-8")).catch((err) => {
    console.error("Error executing schema.sql:", err);
    throw err;
  });

  provide("databaseUrl", url);

  return async function teardown() {
    await pool.end();
    await postgresContainer.stop();
  };
}

declare module "vitest" {
  export interface ProvidedContext {
    databaseUrl: string;
  }
}