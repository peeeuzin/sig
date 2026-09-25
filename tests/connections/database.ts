import { Pool } from "pg";
import { afterAll, beforeAll, inject } from "vitest";

let pool: Pool;

beforeAll(async () => {
  pool = new Pool({
    connectionString: inject("databaseUrl"),
    allowExitOnIdle: true,
    idleTimeoutMillis: 1000, // Set idle timeout to 1
  });

  await pool.query("SELECT 1");
});

afterAll(async () => {
  await pool.end();
});

export { pool };