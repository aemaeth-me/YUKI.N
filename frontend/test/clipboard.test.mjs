import assert from "node:assert/strict";
import test from "node:test";
import { copyToClipboard } from "../web/clipboard.js";

test("copies through the modern clipboard API", async () => {
  let copied = "";
  const result = await copyToClipboard("answer", {
    writeText: async (text) => {
      copied = text;
    },
  });
  assert.equal(result, true);
  assert.equal(copied, "answer");
});

test("reports an unavailable clipboard without throwing", async () => {
  assert.equal(await copyToClipboard("answer", undefined, undefined), false);
});
