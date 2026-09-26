import { appendFileSync } from "node:fs";
import { test } from "node:test";

test("node test fixture runs once", () => {
  appendFileSync(process.env.TALLY_SHARDS, "node-test\n");
});
