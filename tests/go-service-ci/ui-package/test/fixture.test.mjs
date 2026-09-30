// Self-test fixture: gives go-service-ci's `ui-test` gate a real test to run.
import assert from "node:assert/strict";
import { test } from "node:test";

test("the fixture's test script runs", () => {
  assert.equal(1 + 1, 2);
});
