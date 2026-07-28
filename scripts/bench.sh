#!/usr/bin/env bash
# bench.sh —— token 对拍：同一任务跑 YUKI.N 与 pi，出双账（markdown 行，贴入 ROADMAP 对账记录）
#
# 用法：
#   scripts/bench.sh                 # 默认任务，双账
#   scripts/bench.sh "任务文本"      # 自定义任务
#   scripts/bench.sh --no-pi         # 只出 YUKI.N 账
#
# 依赖：python3、curl、lsof；DEEPSEEK_API_KEY（YUKI.N 侧）；pi（可选，--no-pi 跳过）

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${YUKI_BENCH_PORT:-18080}"
TASK="列出 src/Yuki/N 目录下所有 .hs 文件的行数，报告行数最多的三个文件及其行数。只做这一件事。"
WITH_PI=1

while [ $# -gt 0 ]; do
  case "$1" in
    --no-pi) WITH_PI=0; shift ;;
    *) TASK="$1"; shift ;;
  esac
done

WORK="$(mktemp -d /tmp/yuki-bench.XXXXXX)"
SERVER_PID=""
cleanup() {
  [ -n "$SERVER_PID" ] && kill -9 "$SERVER_PID" 2>/dev/null || true
  lsof -ti :"$PORT" 2>/dev/null | xargs kill -9 2>/dev/null || true
}
trap cleanup EXIT

echo "== bench: $TASK" >&2

# --- YUKI.N 侧 ---
cd "$REPO_ROOT"
YUKI_PORT="$PORT" \
YUKI_JOURNAL_DIR="$WORK/journal" \
YUKI_ARTIFACT_DIR="$WORK/artifacts" \
YUKI_WORK_DIR="$REPO_ROOT" \
  cabal run yuki-n > "$WORK/server.log" 2>&1 &
SERVER_PID=$!

for _ in $(seq 1 90); do
  curl -s -o /dev/null "http://127.0.0.1:$PORT/config" && break
  sleep 2
done
curl -s -o /dev/null "http://127.0.0.1:$PORT/config" || { echo "server did not start" >&2; exit 1; }

curl -sN -X POST "http://127.0.0.1:$PORT/agent" \
  -H 'Content-Type: application/json' \
  -d "$(python3 -c 'import json,sys; print(json.dumps({"threadId":"bench","runId":"bench-1","messages":[{"id":"u","role":"user","content":sys.argv[1]}]}))' "$TASK")" \
  > "$WORK/yuki.sse"

python3 - "$WORK/yuki.sse" > "$WORK/yuki.account" <<'PY'
import json, sys
usage, tools = [], []
for line in open(sys.argv[1]):
    if not line.startswith("data: "): continue
    e = json.loads(line[6:])
    if e.get("type") == "CUSTOM" and e.get("name") == "usage": usage.append(e["value"])
    if e.get("type") == "TOOL_CALL_START": tools.append(e.get("toolCallName"))
p = sum(u.get("promptTokens") or 0 for u in usage)
c = sum(u.get("completionTokens") or 0 for u in usage)
h = sum(u.get("cacheHitTokens") or 0 for u in usage)
print(f"{len(usage)}|{p}|{p-h}|{h}|{c}|{','.join(tools)}")
PY

IFS='|' read -r TURNS PROMPT MISS HIT COMPLETION TOOLS < "$WORK/yuki.account"
echo "yuki.n: turns=$TURNS prompt=$PROMPT (miss $MISS / hit $HIT) completion=$COMPLETION tools=[$TOOLS]" >&2

# --- pi 侧 ---
PI_ACCOUNT="(skipped)"
if [ "$WITH_PI" -eq 1 ]; then
  (cd "$REPO_ROOT" && pi -p --session-dir "$WORK/pi-sessions" "$TASK" > "$WORK/pi.log" 2>&1) || true
  PI_ACCOUNT=$(python3 - "$WORK/pi-sessions" <<'PY'
import json, glob, os, sys
files = sorted(glob.glob(os.path.join(sys.argv[1], "**/*.jsonl"), recursive=True), key=os.path.getmtime)
if not files:
    print("(pi session not found)"); raise SystemExit
tot, turns, tools = {}, 0, []
for line in open(files[-1]):
    try: e = json.loads(line)
    except: continue
    m = e.get("message") or {}
    u = m.get("usage") or e.get("usage")
    if isinstance(u, dict) and any(u.values()):
        turns += 1
        for k, v in u.items():
            if isinstance(v, (int, float)) and "cost" not in k.lower(): tot[k] = tot.get(k, 0) + v
    tc = m.get("toolName") or (m.get("toolCall") or {}).get("name")
    if tc: tools.append(tc)
print(f"turns={turns} input={tot.get('input',0)} output={tot.get('output',0)} cacheRead={tot.get('cacheRead',0)} tools={tools}")
PY
)
  echo "pi: $PI_ACCOUNT" >&2
fi

# --- markdown 行 ---
DATE=$(date +%F)
echo "| ${DATE} | （里程碑） | ${TASK} | deepseek-v4-pro：${TURNS} 轮、tools [${TOOLS}]；prompt ${PROMPT}（miss ${MISS} / hit ${HIT}）、completion ${COMPLETION} | ${PI_ACCOUNT} | （判定） |"
