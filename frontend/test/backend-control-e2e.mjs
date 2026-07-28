import assert from "node:assert/strict";
import { postAgentControl } from "../web/control.js";

const base = new URL(process.argv[2]);
const endpoint = new URL("agent", base).href;
const runId = "browser-control-e2e";
const response = await fetch(endpoint, {
  method: "POST",
  headers: {
    accept: "text/event-stream",
    "content-type": "application/json",
  },
  body: JSON.stringify({
    threadId: "browser-control-thread",
    runId,
    state: {},
    messages: [{ id: "user-1", role: "user", content: "hello" }],
    tools: [],
    context: [],
    forwardedProps: {},
  }),
  signal: AbortSignal.timeout(10_000),
});

assert.equal(response.status, 200);
assert.ok(response.body, "backend did not return an SSE body");

const reader = response.body.getReader();
const decoder = new TextDecoder();
let stream = "";

while (!stream.includes('"type":"RUN_STARTED"')) {
  const { value, done } = await reader.read();
  assert.equal(done, false, "run ended before RUN_STARTED");
  stream += decoder.decode(value, { stream: true });
}

const control = await postAgentControl({ endpoint, runId }, "cancel");
assert.equal(control.status, 202);

while (true) {
  const { value, done } = await reader.read();
  stream += decoder.decode(value, { stream: !done });
  if (done) break;
}

assert.match(stream, /"name":"run\.cancelled"/);
assert.match(stream, /"type":"RUN_FINISHED"/);
