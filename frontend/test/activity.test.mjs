import assert from "node:assert/strict";
import test from "node:test";
import { startActivityStream } from "../web/activity.js";

const makeFakeEventSource = () => {
  class FakeEventSource {
    static instances = [];

    constructor(url) {
      this.url = url;
      this.listeners = new Map();
      this.closed = false;
      FakeEventSource.instances.push(this);
    }

    addEventListener(type, listener) {
      const listeners = this.listeners.get(type) ?? [];
      listeners.push(listener);
      this.listeners.set(type, listeners);
    }

    dispatch(type, event = {}) {
      for (const listener of this.listeners.get(type) ?? []) listener(event);
    }

    close() {
      this.closed = true;
    }
  }
  return FakeEventSource;
};

const harness = () => {
  const frames = [];
  const connections = [];
  const Fake = makeFakeEventSource();
  globalThis.EventSource = Fake;
  const stream = startActivityStream({
    onFrame: (frame) => frames.push(frame),
    onConnection: (state) => connections.push(state),
  });
  return { stream, source: Fake.instances.at(-1), frames, connections, Fake };
};

test("connects to the activity stream and dispatches parsed frames", () => {
  const state = harness();
  assert.equal(state.source.url, "/activity/stream");
  assert.deepEqual(state.frames, []);

  state.source.dispatch("status", {
    data: JSON.stringify({ runId: "run-1", phase: "running" }),
  });
  state.source.dispatch("snapshot", {
    data: JSON.stringify({ runs: [], incarnations: [] }),
  });

  assert.deepEqual(state.frames, [
    { kind: "status", data: { runId: "run-1", phase: "running" } },
    { kind: "snapshot", data: { runs: [], incarnations: [] } },
  ]);
});

test("malformed frame data is ignored without killing the stream", () => {
  const state = harness();
  state.source.dispatch("status", { data: "{not json" });
  state.source.dispatch("draft", { data: "" });

  assert.deepEqual(state.frames, []);
  assert.deepEqual(state.connections, []);
});

test("three consecutive errors degrade the connection exactly once", () => {
  const state = harness();
  state.source.onerror();
  state.source.onerror();
  assert.deepEqual(state.connections, []);

  state.source.onerror();
  assert.deepEqual(state.connections, ["degraded"]);

  state.source.onerror();
  assert.deepEqual(state.connections, ["degraded"]);
});

test("reopening reports live and resets the failure counter", () => {
  const state = harness();
  state.source.onerror();
  state.source.onerror();
  state.source.onerror();
  assert.deepEqual(state.connections, ["degraded"]);

  state.source.onopen();
  assert.deepEqual(state.connections, ["degraded", "live"]);

  state.source.onerror();
  state.source.onerror();
  assert.deepEqual(state.connections, ["degraded", "live"]);

  state.source.onerror();
  assert.deepEqual(state.connections, ["degraded", "live", "degraded"]);
});

test("stop closes the current source and restart reconnects", () => {
  const state = harness();
  state.stream.stop();
  assert.equal(state.source.closed, true);

  state.stream.restart();
  const next = state.Fake.instances.at(-1);
  assert.equal(state.Fake.instances.length, 2);
  assert.equal(next.url, "/activity/stream");
  assert.equal(next.closed, false);
});
