#!/usr/bin/env bash
# Merge planner4mcp into Cursor's user-level MCP config.
# Idempotent: backs the file up first and leaves every other server alone.
# Paths are discovered, so the same script works on another Mac.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CFG="$HOME/.cursor/mcp.json"
LAUNCHER="$REPO/bin/planner4mcp"
ENTRY_PATH="$REPO/dist/index.js"

[ -f "$ENTRY_PATH" ] || { echo "✗ 找不到 $ENTRY_PATH —— 先跑 npm install && npm run build"; exit 1; }
[ -x "$LAUNCHER" ] || { echo "✗ 找不到可执行的 $LAUNCHER"; exit 1; }

echo "仓库:    $REPO"
echo "启动器:  $LAUNCHER"

mkdir -p "$(dirname "$CFG")"
if [ -f "$CFG" ]; then
  BAK="$CFG.bak.$(date +%Y%m%d-%H%M%S)"
  cp "$CFG" "$BAK"
  echo "已备份 → $BAK"
else
  echo '{}' > "$CFG"
  echo "配置文件不存在，已新建"
fi

CFG="$CFG" LAUNCHER="$LAUNCHER" python3 <<'PY'
import json, os

cfg_path = os.environ["CFG"]
with open(cfg_path) as f:
    raw = f.read().strip() or "{}"
cfg = json.loads(raw)

servers = cfg.setdefault("mcpServers", {})
print("现有 MCP server:", ", ".join(servers) or "(无)")

before = servers.get("planner4mcp")
# The launcher resolves the repo and a Node >= 18 at spawn time, so this entry
# survives a node upgrade or an nvm switch that moves the interpreter.
servers["planner4mcp"] = {"command": os.environ["LAUNCHER"]}

if before == servers["planner4mcp"]:
    print("planner4mcp 已存在且配置一致，未改动")
else:
    with open(cfg_path, "w") as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print("✓ 已写入 planner4mcp")

print("写入后 MCP server:", ", ".join(servers))
PY

echo
echo "下一步：重载 Cursor 窗口，或在 Settings → MCP 里确认 planner4mcp 已启用。"
