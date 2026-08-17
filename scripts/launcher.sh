#!/bin/bash
# DShLauncher 启动器:双击运行 = 自动启动 DeepSeek Harness 并打开 PWA
# 启动期间显示进度对话框(已等待秒数,就绪/失败自动消失);失败弹错误对话框可打开日志
DIR="$(cd "$(dirname "$0")" && pwd)"
RES="$(cd "$DIR/../Resources" && pwd)"
RT_HOME="${DSH_RT_HOME:-$HOME/.local/share/dsh-runtime}"
RT_STATE="${DSH_RT_STATE:-$HOME/.local/state/dsh-runtime}"
LOG_DIR="$RT_STATE/logs"
RUN_LOG="/tmp/dsh-launcher-$$.log"
URL="http://127.0.0.1:${DSH_RT_PORT:-3080}/"

# 已就绪:跳过一切对话框,直接交给 dshctl 打开 PWA(秒开)
if curl -fsS -o /dev/null --max-time 2 "$URL" 2>/dev/null; then
  "$RES/wrapper.sh" start >"$RUN_LOG" 2>&1
  RC=$?
  rm -f "$RUN_LOG"
  exit "$RC"
fi

FIRST_RUN=0
if [ ! -x "$RT_HOME/node/bin/node" ] || [ ! -f "$RT_HOME/app/node_modules/@deepseek-ai/dsh/package.json" ]; then
  FIRST_RUN=1
fi

# 阶段 1:后台启动 wrapper,期间循环刷新进度对话框(就绪/失败后自动消失)
"$RES/wrapper.sh" start >"$RUN_LOG" 2>&1 &
WRAP=$!

DIALOG_PID=""
SEC=0
while kill -0 "$WRAP" 2>/dev/null; do
  if [ "$SEC" -ge 20 ]; then
    MSG="DeepSeek Harness 启动缓慢(已等待 ${SEC}s)…\n完整日志: $LOG_DIR"
  elif [ "$FIRST_RUN" = "1" ] && [ "$SEC" -lt 3 ]; then
    MSG="首次运行:正在准备包内内置运行时(数秒)。\n正在启动 DeepSeek Harness…"
  elif [ "$SEC" -eq 0 ]; then
    MSG="正在启动 DeepSeek Harness…"
  else
    MSG="正在启动 DeepSeek Harness…(已等待 ${SEC}s)"
  fi
  kill "$DIALOG_PID" 2>/dev/null
  osascript -e "display dialog \"$MSG\" giving up after 3 with title \"DeepSeek Harness\"" >/dev/null 2>&1 &
  DIALOG_PID=$!
  sleep 3
  SEC=$((SEC+3))
done
kill "$DIALOG_PID" 2>/dev/null
wait "$WRAP"
RC=$?

# 阶段 2:失败对话框(带退出码与最近日志摘录,可一键打开日志目录)
if [ "$RC" -ne 0 ]; then
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  RECENT="$(ls -t "$LOG_DIR"/*.log 2>/dev/null | head -1)"
  ERR="$(tail -n 6 "$RUN_LOG" 2>/dev/null | tr '\n' ' ' | sed 's/"/\"/g' | cut -c1-240)"
  [ -z "$ERR" ] && [ -n "$RECENT" ] && ERR="$(tail -n 3 "$RECENT" | tr '\n' ' ' | sed 's/"/\"/g' | cut -c1-240)"
  [ -n "$ERR" ] && DETAIL="\n\n$ERR"
  BTN="$(osascript -e "display dialog \"DeepSeek Harness 启动失败 (rc=$RC)。$DETAIL\n\n完整日志: $LOG_DIR\" buttons {\"退出\",\"打开日志目录\"} default button \"打开日志目录\" with title \"DeepSeek Harness\"" 2>/dev/null)"
  case "$BTN" in
    *"打开日志目录"*) open "$LOG_DIR" 2>/dev/null || true ;;
  esac
  exit "$RC"
fi
rm -f "$RUN_LOG"
exit 0