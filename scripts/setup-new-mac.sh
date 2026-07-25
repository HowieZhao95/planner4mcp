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

# ─── 5. PLANNER4MCP_HOME ────────────────────────────────────────
# 跟着 iCloud / git 同步的 .mcp.json 里写的是
#   ${PLANNER4MCP_HOME:-<某台机器的绝对路径>}/bin/planner4mcp
# 所以每台机器都要让这个变量指向本机的仓库。
#
# 只写 shell profile 是不够的：GUI 启动的 App（Claude 桌面端，以及它内嵌的
# claude-code）不继承登录 shell 的环境变量，会静默回落到默认路径。所以同时用
# LaunchAgent 在每次登录时 launchctl setenv，让 GUI 进程也能读到。
echo "── 设置 PLANNER4MCP_HOME ──"
PLIST="$HOME/Library/LaunchAgents/com.howiez.planner4mcp.env.plist"
mkdir -p "$(dirname "$PLIST")"
cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>com.howiez.planner4mcp.env</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/launchctl</string>
		<string>setenv</string>
		<string>PLANNER4MCP_HOME</string>
		<string>$REPO</string>
	</array>
	<key>RunAtLoad</key><true/>
</dict>
</plist>
PLISTEOF

GUI="gui/$(id -u)"
launchctl bootout "$GUI/com.howiez.planner4mcp.env" 2>/dev/null || true
launchctl bootstrap "$GUI" "$PLIST" 2>/dev/null || launchctl load "$PLIST" 2>/dev/null || true
launchctl setenv PLANNER4MCP_HOME "$REPO"   # 当前登录会话立即生效
echo "✓ GUI 会话已生效（LaunchAgent: $PLIST）"

# 终端场景
PROFILE="$HOME/.zshrc"
LINE="export PLANNER4MCP_HOME=\"$REPO\""
if [ -f "$PROFILE" ] && grep -qF "PLANNER4MCP_HOME" "$PROFILE"; then
  echo "✓ $PROFILE 里已有 PLANNER4MCP_HOME，未重复写入（如指向旧路径请手动改成 $REPO）"
else
  printf '\n# planner4mcp\n%s\n' "$LINE" >> "$PROFILE"
  echo "✓ 已追加到 $PROFILE"
fi
echo

echo "── 注册到 Claude Code（可选，终端里用）──"
echo "在你想用它的项目目录下跑："
echo "  claude mcp add planner4mcp -- $REPO/bin/planner4mcp"
echo
echo "全部完成。Cmd+Q 退出 Claude 桌面端再重开即可生效。"
