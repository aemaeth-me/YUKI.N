import { createReadStream, statSync } from "node:fs";
import http from "node:http";
import { fileURLToPath } from "node:url";
import path from "node:path";
import {
  defaultBackendPort,
  defaultFrontendPort,
  proxyBackendPath,
} from "../../scripts/local-support.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../dist");
const host = "127.0.0.1";
const port = Number.parseInt(
  process.env.YUKI_FRONTEND_PORT ?? String(defaultFrontendPort),
  10,
);
const backend = new URL(
  process.env.YUKI_BACKEND_URL ??
    `http://127.0.0.1:${defaultBackendPort}`,
);

const mime = {
  ".css": "text/css; charset=utf-8",
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".svg": "image/svg+xml",
};

const hopByHop = new Set([
  "connection",
  "keep-alive",
  "proxy-authenticate",
  "proxy-authorization",
  "proxy-connection",
  "te",
  "trailer",
  "transfer-encoding",
  "upgrade",
]);

const passHeaders = (headers) =>
  Object.fromEntries(
    Object.entries(headers).filter(([name]) => !hopByHop.has(name)),
  );

const stat = (file) => {
  try {
    return statSync(file).isFile();
  } catch {
    return false;
  }
};

const proxyAgent = (request, response) => {
  const target = new URL(request.url ?? "/agent", backend);
  const upstream = http.request(
    target,
    {
      method: request.method,
      headers: { ...passHeaders(request.headers), host: target.host },
    },
    (incoming) => {
      response.writeHead(incoming.statusCode ?? 502, passHeaders(incoming.headers));
      incoming.pipe(response);
    },
  );

  upstream.on("error", (error) => {
    if (!response.headersSent) {
      response.writeHead(502, { "content-type": "application/json; charset=utf-8" });
    }
    response.end(JSON.stringify({ error: `backend unavailable: ${error.message}` }));
  });
  request.on("aborted", () => upstream.destroy());
  response.on("close", () => upstream.destroy());
  request.pipe(upstream);
};

const serveFile = (request, response) => {
  const requested = new URL(request.url ?? "/", "http://localhost").pathname;
  const relative = requested === "/" ? "index.html" : requested.replace(/^\/+/, "");
  const candidate = path.resolve(root, relative);
  const file =
    candidate.startsWith(`${root}${path.sep}`) && stat(candidate)
      ? candidate
      : path.join(root, "index.html");

  response.writeHead(200, {
    "cache-control": "no-store",
    "content-type": mime[path.extname(file)] ?? "application/octet-stream",
  });
  createReadStream(file).pipe(response);
};

http
  .createServer((request, response) =>
    proxyBackendPath(new URL(request.url ?? "/", "http://localhost").pathname)
      ? proxyAgent(request, response)
      : serveFile(request, response),
  )
  .listen(port, host, () => {
    console.log(`YUKI.N AG-UI workbench: http://${host}:${port}`);
    console.log(`Proxying /agent to ${new URL("/agent", backend)}`);
  });
