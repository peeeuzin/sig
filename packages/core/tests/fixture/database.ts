import { vi } from "vitest";
import type { DatabaseAdapter } from "../../src/adapters/database";

export const mockDatabaseAdapter: DatabaseAdapter = {
  create: vi.fn(),
  findOne: vi.fn(),
  findMany: vi.fn(),
  count: vi.fn(),
  update: vi.fn(),
  updateMany: vi.fn(),
  delete: vi.fn(),
  transaction: vi.fn(),
};