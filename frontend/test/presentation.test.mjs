import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const source = new URL("../src/Yuki/View/Conversation.elm", import.meta.url);
const styles = new URL("../web/styles.css", import.meta.url);

test("tool calls without assistant text get a first-class timeline item", async () => {
  const conversation = await readFile(source, "utf8");

  assert.match(conversation, /ToolCallMessage identifier ->/);
  assert.match(conversation, /isToolOnlyAssistant assistant/);
  assert.match(conversation, /viewToolBatch model/);
  assert.match(conversation, /collectToolCalls \[ identifier \] rest/);
  assert.doesNotMatch(conversation, /sameToolTurn/);
  assert.match(conversation, /turn yuki tool-turn/);
  assert.doesNotMatch(conversation, /detached-tools/);
});

test("streaming reasoning stays open and can be followed", async () => {
  const conversation = await readFile(source, "utf8");

  assert.match(conversation, /data-streaming/);
  assert.match(conversation, /reasoning-copy/);
});

test("concurrent tool calls are grouped and bounded", async () => {
  const css = await readFile(styles, "utf8");

  assert.match(css, /\.tool-batch-body\s*\{[\s\S]*max-height: min\(30rem, 52vh\)/);
});

test("frontend surfaces use square corners", async () => {
  const css = await readFile(styles, "utf8");
  const radii = [...css.matchAll(/border-radius:\s*([^;]+)/g)].map((match) =>
    match[1].trim(),
  );

  assert.ok(radii.length > 0);
  assert.deepEqual([...new Set(radii)], ["0"]);
});

test("content cards use tonal separation instead of outline borders", async () => {
  const css = await readFile(styles, "utf8");

  assert.match(css, /\.turn\s*\{[\s\S]{0,220}border: 0/);
  assert.match(css, /\.aside-line,\s*\.aside-block\s*\{[\s\S]{0,260}border: 0/);
  assert.match(css, /\.tool-batch > summary\s*\{[\s\S]{0,320}background:/);
  assert.match(css, /\.paper-dialog\s*\{[\s\S]{0,180}border: 0/);
  assert.doesNotMatch(css, /\.turn\.yuki\s*\{[\s\S]{0,180}border-left/);
});

test("streaming chunks animate without replaying the whole answer", async () => {
  const conversation = await readFile(source, "utf8");
  const css = await readFile(styles, "utf8");

  assert.match(conversation, /viewStreamChunks assistant\.chunks/);
  assert.match(conversation, /viewStreamChunks reasoning\.chunks/);
  assert.match(css, /\.stream-chunk\s*\{[\s\S]*animation: stream-chunk-in/);
  assert.match(css, /@keyframes stream-chunk-in/);
  assert.doesNotMatch(css, /animation: answer-settle/);
});
