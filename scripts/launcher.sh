#!/bin/bash
# DShLauncher 启动器:双击运行 = 自动启动 DeepSeek Harness 并打开 PWA
# 首次运行用包内内置运行时(数秒),失败时弹出错误对话框并可打开日志目录
DIR="$(cd "$(dirname "$0")" && pwd)"
RES="$(cd "$DIR/../Resources" && pwd)"
RT_HOME="${DSH_RT_HOME:-$HOME/.local/share/dsh-runtime}"
RT_STATE="${DSH_RT_STATE:-$HOME/.local/state/dsh-runtime}"
LOG_DIR="$RT_STATE/logs"
RUN_LOG="/tmp/dsh-launcher-$$.log"

# 阶段 0:首次运行提示(5 秒自动消失,不阻塞准备过程)
if [ ! -x "$RT_HOME/node/bin/node" ] || [ ! -f "$RT_HOME/app/node_modules/@deepseek-ai/dsh/package.json" ]; then
  osascript -e 'display dialog "首次运行:正在准备 DeepSeek Harness 运行时(包内已内置,数秒即可)。\n完成后 Safari 会自动打开,请稍候。" giving up after 5 with title "DeepSeek Harness"' >/dev/null 2>&1 || true
fi

# 阶段 1:启动(输出写入临时日志,便于失败时提取原因)
"$RES/wrapper.sh" start >"$RUN_LOG" 2>&1
RC=$?
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