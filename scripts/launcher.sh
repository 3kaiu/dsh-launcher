#!/bin/bash
# DeepSeek Harness —— 一次性设置入口(双击 .app 或首次安装时使用)
# 职责:注册常驻唤醒守护(LaunchAgent)→ 确保守护在线 → 打开 PWA 入口(唯一端口,自动匹配)。
# 日常使用:直接点击程序坞里的「DeepSeek Harness」PWA 即可,引导页会自动拉起 dsh,无需再打开本 App。
DIR="$(cd "$(dirname "$0")" && pwd)"
RES="$(cd "$DIR/../Resources" && pwd)"
RT_HOME="${DSH_RT_HOME:-$HOME/.local/share/dsh-runtime}"
RT_STATE="${DSH_RT_STATE:-$HOME/.local/state/dsh-runtime}"
LOG_DIR="$RT_STATE/logs"
AGENT_DIR="$HOME/Library/LaunchAgents"
AGENT="$AGENT_DIR/com.dshlauncher.daemon.plist"
AGENT_LABEL="com.dshlauncher.daemon"
URL="http://127.0.0.1:${DSH_RT_PORT:-3080}/"
mkdir -p "$AGENT_DIR" "$LOG_DIR"

# 1) 注册守护 LaunchAgent(幂等:已存在则跳过生成,但每次刷新加载状态)
if [ ! -f "$AGENT" ] && [ -f "$RES/com.dshlauncher.daemon.plist" ]; then
  sed -e "s|__DAEMON_BIN__|$RES/daemon|g" \
      -e "s|__RT_HOME__|$RT_HOME|g" \
      -e "s|__RT_STATE__|$RT_STATE|g" \
      -e "s|__LOG_DIR__|$LOG_DIR|g" "$RES/com.dshlauncher.daemon.plist" > "$AGENT"
fi
launchctl bootstrap "gui/$(id -u)" "$AGENT" 2>/dev/null \
  || launchctl enable "gui/$(id -u)/$AGENT_LABEL" 2>/dev/null || true
launchctl kickstart -k "gui/$(id -u)/$AGENT_LABEL" 2>/dev/null || true

# 2) 守护未响应则直接拉起(兜底:Agent 未加载/用户未登录会话);端口被占用(如无守护直启的 dsh)则不拉起
if ! curl -fsS -o /dev/null --max-time 2 "$URL/health"; then
  if ! lsof -tiTCP:"${DSH_RT_PORT:-3080}" -sTCP:LISTEN >/dev/null 2>&1; then
    nohup "$RES/daemon" >>"$LOG_DIR/daemon.log" 2>&1 &
  fi
fi

# 3) 打开 PWA 入口(唯一端口):dsh 未运行 → 引导页自动拉起;已运行 → 直连 UI
open "$URL"
exit 0