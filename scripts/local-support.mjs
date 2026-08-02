import net from "node:net";

export const defaultBackendPort = 18080;
export const defaultFrontendPort = 15173;
const backendPrefixes = [
  "/agent",
  "/activity",
  "/fleet",
  "/dispatches",
  "/memory",
  "/artifacts",
  "/journal",
  "/replay",
  "/config",
  "/providers",
  "/models",
  "/threads",
  "/incarnations",
  "/prompts",
];

export const loopbackHost = (host) =>
  new Set(["127.0.0.1", "localhost", "::1"]).has(host);

export const parsePort = (name, raw) => {
  const value = Number(raw);
  if (!Number.isInteger(value) || value < 1 || value > 65535) {
    throw new Error(`${name} 必须是 1–65535 之间的整数，当前为 ${raw}`);
  }
  return value;
};

export const proxyBackendPath = (pathname) =>
  backendPrefixes.some(
    (prefix) => pathname === prefix || pathname.startsWith(`${prefix}/`),
  );

export const portAvailable = (host, port, createServer = net.createServer) =>
  new Promise((resolve) => {
    const server = createServer();
    server.unref();
    server.once("error", () => resolve(false));
    server.listen({ host, port, exclusive: true }, () =>
      server.close(() => resolve(true)),
    );
  });

export const waitForListening = async (
  host,
  port,
  {
    timeoutMs = 15000,
    probe = portAvailable,
    pause = (milliseconds) =>
      new Promise((resolve) => setTimeout(resolve, milliseconds)),
  } = {},
) => {
  const deadline = Date.now() + timeoutMs;
  while (await probe(host, port)) {
    if (Date.now() >= deadline) {
      throw new Error(`${host}:${port} 未在 ${timeoutMs}ms 内开始监听`);
    }
    await pause(50);
  }
};
