#!/bin/bash
# DShLauncher 启动器:双击运行 = 自动启动 DeepSeek Harness 并打开 PWA
# 调用内嵌 dshctl(wrapper.sh),首次自动下载 node 最新 LTS + 官方 dsh latest,之后自动升级
DIR="$(cd "$(dirname "$0")" && pwd)"
RES="$(cd "$DIR/../Resources" && pwd)"
"$RES/wrapper.sh" start
RC=$?
if [ "$RC" -ne 0 ]; then
  osascript -e "display dialog \"DeepSeek Harness 启动失败 (rc=$RC)。\n详情见 ~/.local/state/dsh-runtime/logs/\" buttons {\"OK\"} default button 1 with title \"DeepSeek Harness\"" >/dev/null 2>&1 || true
fi
exit "$RC"
