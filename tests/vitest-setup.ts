import { readFileSync } from "node:fs";
import path from "node:path";
import { PostgreSqlContainer } from "@testcontainers/postgresql";
import { RedisContainer } from "@testcontainers/redis";
import { Pool } from "pg";
import type { TestProject } from "vitest/node";

const schemaSqlPath = path.join(__dirname, "fixture", "schema.sql");

export default async function setup({ provide }: TestProject) {
  const postgresContainer = await new PostgreSqlContainer(
    "postgres:17",
  ).start();

  const redisContainer = await new RedisContainer("redis:7").start();

  const postgresUrl = postgresContainer.getConnectionUri();
  const redisUrl = redisContainer.getConnectionUrl();

  const pool = new Pool({ connectionString: postgresUrl });

  await pool.query(readFileSync(schemaSqlPath, "utf-8")).catch((err) => {
    console.error("Error executing schema.sql:", err);
    throw err;
  });

  provide("databaseUrl", postgresUrl);
  provide("redisUrl", redisUrl);

  return async function teardown() {
    await pool.end();
    await postgresContainer.stop();
    await redisContainer.stop();
  };
}

declare module "vitest" {
  export interface ProvidedContext {
    databaseUrl: string;
    redisUrl: string;
  }
}