#!/usr/bin/env bash
# 把 planner4mcp 合并进 Claude 桌面端 MCP 配置（幂等，先备份，不覆盖已有条目）
# 路径与 node 全部自动探测，可在任意 Mac 上直接跑。
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENTRY_PATH="$REPO/dist/index.js"
CFG="$HOME/Library/Application Support/Claude/claude_desktop_config.json"

# --- 找一个 >=18 的 node（系统默认可能是 v16，太老）---
pick_node() {
  for c in "$(command -v node || true)" /opt/homebrew/bin/node /usr/local/bin/node; do
    [ -n "$c" ] && [ -x "$c" ] || continue
    v="$("$c" -e 'process.stdout.write(String(process.versions.node.split(".")[0]))' 2>/dev/null || echo 0)"
    if [ "$v" -ge 18 ] 2>/dev/null; then echo "$c"; return 0; fi
  done
  return 1
}
NODE_BIN="$(pick_node)" || { echo "✗ 找不到 Node 18+。装 Homebrew node 或 nvm use 24 后重试"; exit 1; }

[ -f "$ENTRY_PATH" ] || { echo "✗ 找不到 $ENTRY_PATH —— 先跑 npm install && npm run build"; exit 1; }

echo "仓库:  $REPO"
echo "Node:  $NODE_BIN ($("$NODE_BIN" -v))"

mkdir -p "$(dirname "$CFG")"
if [ -f "$CFG" ]; then
  BAK="$CFG.bak.$(date +%Y%m%d-%H%M%S)"
  cp "$CFG" "$BAK"
  echo "已备份 → $BAK"
else
  echo '{}' > "$CFG"
  echo "配置文件不存在，已新建"
fi

LAUNCHER="$REPO/bin/planner4mcp"
[ -x "$LAUNCHER" ] || { echo "✗ 找不到可执行的 $LAUNCHER"; exit 1; }

CFG="$CFG" LAUNCHER="$LAUNCHER" python3 <<'PY'
import json, os

cfg_path = os.environ["CFG"]
with open(cfg_path) as f:
    raw = f.read().strip() or "{}"
cfg = json.loads(raw)

servers = cfg.setdefault("mcpServers", {})
print("现有 MCP server:", ", ".join(servers) or "(无)")

before = servers.get("planner4mcp")
# Point at the launcher rather than at a specific node binary: it resolves the
# repo and a Node >= 18 at spawn time, so this entry survives a node upgrade or
# an nvm switch that moves the interpreter out from under us.
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
echo "下一步：完全退出 Claude 桌面端（Cmd+Q，不是关窗口）再重开。"
