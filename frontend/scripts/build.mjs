import { copyFile, mkdir } from "node:fs/promises";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const dist = path.join(root, "dist");

await mkdir(dist, { recursive: true });

const result = spawnSync(
  "elm",
  ["make", "src/Main.elm", "--optimize", "--output=dist/elm.js"],
  {
    cwd: root,
    stdio: "inherit",
    env: { ...process.env, ELM_HOME: path.join(root, ".elm-home") },
  },
);

if (result.error) {
  console.error(result.error.message);
  process.exit(1);
}

if (result.status !== 0) {
  process.exit(result.status ?? 1);
}

await Promise.all(
  [
    "index.html",
    "app.js",
    "clipboard.js",
    "scroll.js",
    "styles.css",
  ].map((file) => copyFile(path.join(root, "web", file), path.join(dist, file))),
);
