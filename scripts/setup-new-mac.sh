#!/usr/bin/env bash
# 在一台新 Mac 上从零装好 planner4mcp。
# 用法：git clone git@github.com:HowieZhao95/planner4mcp.git && cd planner4mcp && bash scripts/setup-new-mac.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"
echo "仓库: $REPO"
echo

# ─── 1. 环境自检 ────────────────────────────────────────────────
echo "── 环境自检 ──"

[ "$(uname -s)" = "Darwin" ] || { echo "✗ 这不是 macOS。planner4mcp 依赖 EventKit，Linux / Windows 上装不了。"; exit 1; }

OSVER="$(sw_vers -productVersion)"
if [ "${OSVER%%.*}" -lt 14 ]; then
  echo "✗ macOS $OSVER —— 需要 14 或更高（用到 requestFullAccessToEvents）"; exit 1
fi
echo "✓ macOS $OSVER  ($(uname -m))"

command -v swiftc >/dev/null || { echo "✗ 找不到 swiftc。跑一次：xcode-select --install"; exit 1; }
echo "✓ swiftc $(swiftc --version 2>/dev/null | head -1)"

pick_node() {
  for c in "$(command -v node || true)" /opt/homebrew/bin/node /usr/local/bin/node; do
    [ -n "$c" ] && [ -x "$c" ] || continue
    v="$("$c" -e 'process.stdout.write(String(process.versions.node.split(".")[0]))' 2>/dev/null || echo 0)"
    if [ "$v" -ge 18 ] 2>/dev/null; then echo "$c"; return 0; fi
  done
  return 1
}
NODE_BIN="$(pick_node)" || { echo "✗ 找不到 Node 18+。brew install node，或 nvm install 24"; exit 1; }
echo "✓ node $("$NODE_BIN" -v) → $NODE_BIN"
echo

# ─── 2. 构建 ────────────────────────────────────────────────────
# Swift 二进制不跨机器：架构来自 uname -m，ad-hoc 签名也必须在本机重建。
echo "── 构建（Swift 桥 + TypeScript）──"
export PATH="$(dirname "$NODE_BIN"):$PATH"
npm install
npm run build
[ -f dist/index.js ] || { echo "✗ 构建后仍无 dist/index.js"; exit 1; }
echo "✓ 构建完成"
echo

# ─── 3. TCC 授权 ────────────────────────────────────────────────
# 授权是每台机器独立的 TCC 数据库，不随 iCloud 或 Apple 账户同步。
echo "── 授权日历与提醒事项 ──"
STATUS="$(./build/ekbridge access.status 2>/dev/null || true)"
if echo "$STATUS" | grep -q '"events" *: *"fullAccess"' && echo "$STATUS" | grep -q '"reminders" *: *"fullAccess"'; then
  echo "✓ 已是 fullAccess，跳过"
else
  echo "会弹两个系统授权框，都点允许："
  ./build/ekbridge --request-access || true
  echo
  echo "授权后状态："
  ./build/ekbridge access.status
  echo "（若仍不是 fullAccess，到 系统设置 › 隐私与安全性 › 日历/提醒事项 里找 planner4mcp 手动打开）"
fi
echo

# ─── 4. 注册 ────────────────────────────────────────────────────
echo "── 注册到 Claude 桌面端 ──"
bash "$REPO/scripts/register-desktop.sh"
echo

echo "── 注册到 Claude Code（可选，终端里用）──"
echo "在你想用它的项目目录下跑："
echo "  claude mcp add planner4mcp -- $NODE_BIN $REPO/dist/index.js"
echo
echo "全部完成。Cmd+Q 退出 Claude 桌面端再重开即可生效。"
