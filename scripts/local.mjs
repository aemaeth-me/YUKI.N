import { existsSync, readdirSync, statSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn, spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import {
  defaultBackendPort,
  defaultFrontendPort,
  loopbackHost,
  parsePort,
  portAvailable,
  waitForListening,
} from "./local-support.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const frontend = path.join(root, "frontend");
const checkOnly = process.argv.includes("--check");
const rebuild = process.argv.includes("--rebuild");

if (process.argv.includes("--help")) {
  console.log("usage: ./yuki [--check] [--rebuild]");
  console.log("  --check  构建并检查依赖、配置与端口，不启动服务");
  console.log("  --rebuild  忽略本机构建缓存，重新构建前后端");
  process.exit(0);
}

const fail = (message) => {
  console.error(`YUKI.N 启动失败：${message}`);
  process.exit(1);
};

const requireCommand = (command, hint) => {
  const result = spawnSync(command, ["--version"], { stdio: "ignore" });
  if (result.error?.code === "ENOENT") fail(`找不到 ${command}；${hint}`);
};

const run = (command, args, options = {}) => {
  const result = spawnSync(command, args, {
    cwd: options.cwd ?? root,
    env: options.env ?? process.env,
    stdio: "inherit",
  });
  if (result.error) fail(`${command} 无法执行：${result.error.message}`);
  if (result.status !== 0) fail(`${command} ${args.join(" ")} 退出码 ${result.status}`);
};

const newestMtime = (target) => {
  if (!existsSync(target)) return 0;
  const info = statSync(target);
  if (!info.isDirectory()) return info.mtimeMs;
  return readdirSync(target, { withFileTypes: true })
    .filter((entry) => !["dist-newstyle", "node_modules", "dist", "elm-stuff", ".elm-home"].includes(entry.name))
    .reduce(
      (latest, entry) => Math.max(latest, newestMtime(path.join(target, entry.name))),
      info.mtimeMs,
    );
};

const stale = (outputs, inputs) => {
  if (outputs.some((output) => !existsSync(output))) return true;
  return Math.min(...outputs.map(newestMtime)) < Math.max(...inputs.map(newestMtime));
};

const locateBackend = () => {
  const located = spawnSync("cabal", ["list-bin", "exe:yuki-n"], {
    cwd: root,
    env: environment,
    encoding: "utf8",
  });
  return located.status === 0 ? located.stdout.trim() : "";
};

requireCommand("cabal", "请先安装 GHC 与 cabal-install");
requireCommand("node", "请安装 Node.js 20 或更高版本");
requireCommand("npm", "请安装 npm");

const host = process.env.YUKI_HOST ?? "127.0.0.1";
if (!loopbackHost(host)) {
  fail(`./yuki 仅供本机使用，YUKI_HOST 必须是 loopback，当前为 ${host}`);
}

let backendPort;
let frontendPort;
try {
  backendPort = parsePort(
    "YUKI_PORT",
    process.env.YUKI_PORT ?? String(defaultBackendPort),
  );
  frontendPort = parsePort(
    "YUKI_FRONTEND_PORT",
    process.env.YUKI_FRONTEND_PORT ?? String(defaultFrontendPort),
  );
} catch (error) {
  fail(error.message);
}

if (backendPort === frontendPort) {
  fail("YUKI_PORT 与 YUKI_FRONTEND_PORT 不能相同");
}
const dataDir =
  process.env.YUKI_DATA_DIR ?? path.join(os.homedir(), ".yuki-n");
const urlHost = host === "::1" ? "[::1]" : host;
const environment = {
  ...process.env,
  YUKI_HOST: host,
  YUKI_PORT: String(backendPort),
  YUKI_FRONTEND_PORT: String(frontendPort),
  YUKI_DATA_DIR: dataDir,
  YUKI_JOURNAL_DIR: process.env.YUKI_JOURNAL_DIR ?? dataDir,
  YUKI_ARTIFACT_DIR: process.env.YUKI_ARTIFACT_DIR ?? dataDir,
  YUKI_WORK_DIR: process.env.YUKI_WORK_DIR ?? root,
  YUKI_BACKEND_URL:
    process.env.YUKI_BACKEND_URL ?? `http://${urlHost}:${backendPort}`,
};

let backend = locateBackend();
const backendInputs = [
  path.join(root, "app"),
  path.join(root, "src"),
  path.join(root, "yuki-n.cabal"),
  path.join(root, "cabal.project"),
];
if (rebuild || !backend || stale([backend], backendInputs)) {
  console.log("YUKI.N：构建 backend（源码有变化或尚未构建）");
  run("cabal", ["build", "exe:yuki-n"], { env: environment });
  backend = locateBackend();
}
if (!backend || !existsSync(backend)) {
  fail("无法定位已构建的 backend");
}

const frontendOutputs = [
  "elm.js",
  "index.html",
  "app.js",
  "clipboard.js",
  "control.js",
  "scroll.js",
  "styles.css",
].map((file) => path.join(frontend, "dist", file));
const frontendInputs = [
  path.join(frontend, "src"),
  path.join(frontend, "web"),
  path.join(frontend, "scripts", "build.mjs"),
  path.join(frontend, "elm.json"),
  path.join(frontend, "package.json"),
  path.join(frontend, "package-lock.json"),
];
if (rebuild || stale(frontendOutputs, frontendInputs)) {
  if (!existsSync(path.join(frontend, "node_modules", ".bin", "elm"))) {
    console.log("YUKI.N：首次安装前端依赖；此步骤可能访问 npm registry");
    run("npm", ["ci"], { cwd: frontend, env: environment });
  }
  console.log("YUKI.N：构建 frontend（源码有变化或尚未构建）");
  run("npm", ["run", "build"], { cwd: frontend, env: environment });
}

run(backend, ["check"], { env: environment });

const ports = await Promise.all([
  portAvailable(host, backendPort),
  portAvailable("127.0.0.1", frontendPort),
]);
if (!ports[0]) fail(`backend 端口 ${host}:${backendPort} 已被占用`);
if (!ports[1]) fail(`frontend 端口 127.0.0.1:${frontendPort} 已被占用`);

if (checkOnly) {
  console.log("YUKI.N 本机启动检查通过。");
  process.exit(0);
}

const backendChild = spawn(backend, [], {
  cwd: root,
  env: environment,
  stdio: "inherit",
});

try {
  await waitForListening(host, backendPort);
} catch (error) {
  backendChild.kill("SIGINT");
  fail(`backend 未就绪：${error.message}`);
}

const frontendChild = spawn("node", ["scripts/dev-server.mjs"], {
  cwd: frontend,
  env: environment,
  stdio: "inherit",
});

try {
  await waitForListening("127.0.0.1", frontendPort);
} catch (error) {
  backendChild.kill("SIGINT");
  frontendChild.kill("SIGINT");
  fail(`frontend 未就绪：${error.message}`);
}

const children = [backendChild, frontendChild];

console.log(`YUKI.N： http://127.0.0.1:${frontendPort}`);

let stopping = false;
let exitCode = 0;

const signalChild = (child, signal) => {
  if (child.exitCode === null && child.signalCode === null) {
    child.kill(signal);
  }
};

const stop = (code = 0) => {
  if (stopping) return;
  stopping = true;
  exitCode = code;
  children.forEach((child) => signalChild(child, "SIGINT"));
  const timer = setTimeout(
    () => children.forEach((child) => signalChild(child, "SIGTERM")),
    4000,
  );
  timer.unref();
};

process.on("SIGINT", () => stop(0));
process.on("SIGTERM", () => stop(0));

await new Promise((resolve) => {
  let exited = 0;
  children.forEach((child) => {
    child.once("error", (error) => {
      console.error(`YUKI.N 子进程失败：${error.message}`);
      stop(1);
    });
    child.once("exit", (code, signal) => {
      exited += 1;
      if (!stopping) {
        console.error(
          `YUKI.N 子进程意外退出：${signal ?? `exit ${code ?? 1}`}`,
        );
        stop(code || 1);
      }
      if (exited === children.length) resolve();
    });
  });
});

process.exit(exitCode);
