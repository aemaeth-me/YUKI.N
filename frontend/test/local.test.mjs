import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import test from "node:test";
import {
  defaultBackendPort,
  defaultFrontendPort,
  loopbackHost,
  parsePort,
  portAvailable,
  proxyBackendPath,
  waitForListening,
} from "../../scripts/local-support.mjs";

test("accepts only loopback hosts", () => {
  assert.equal(loopbackHost("127.0.0.1"), true);
  assert.equal(loopbackHost("::1"), true);
  assert.equal(loopbackHost("0.0.0.0"), false);
});

test("validates local ports", () => {
  assert.equal(defaultBackendPort, 18080);
  assert.equal(defaultFrontendPort, 15173);
  assert.equal(parsePort("PORT", "8080"), 8080);
  assert.throws(() => parsePort("PORT", "0"), /1–65535/);
});

test("proxies every backend-owned product route", () => {
  assert.equal(proxyBackendPath("/agent"), true);
  assert.equal(proxyBackendPath("/agent/run"), true);
  assert.equal(proxyBackendPath("/threads/abc"), true);
  assert.equal(proxyBackendPath("/config/threads"), true);
  assert.equal(proxyBackendPath("/artifacts/xyz"), true);
  assert.equal(proxyBackendPath("/incarnations-archive"), false);
  assert.equal(proxyBackendPath("/styles.css"), false);
});

test("distinguishes occupied and available ports", async () => {
  const fakeServer = (occupied) => () => {
    const server = new EventEmitter();
    server.unref = () => server;
    server.close = (done) => done();
    server.listen = (_options, ready) =>
      queueMicrotask(() => (occupied ? server.emit("error") : ready()));
    return server;
  };

  assert.equal(
    await portAvailable("127.0.0.1", 8080, fakeServer(true)),
    false,
  );
  assert.equal(
    await portAvailable("127.0.0.1", 8080, fakeServer(false)),
    true,
  );
});

test("waits until a child starts listening", async () => {
  let attempts = 0;
  await waitForListening("127.0.0.1", 8080, {
    probe: async () => ++attempts < 3,
    pause: async () => {},
  });
  assert.equal(attempts, 3);

  await assert.rejects(
    waitForListening("127.0.0.1", 8080, {
      timeoutMs: 0,
      probe: async () => true,
      pause: async () => {},
    }),
    /未在 0ms 内开始监听/,
  );
});
