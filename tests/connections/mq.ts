import IORedis from "ioredis";
import { afterAll, beforeAll, inject } from "vitest";

let redis: IORedis;

beforeAll(async () => {
  redis = new IORedis(inject("redisUrl"), {
    lazyConnect: true,
    maxRetriesPerRequest: null,
  });
});

afterAll(async () => {
  redis.disconnect();
});

export { redis };