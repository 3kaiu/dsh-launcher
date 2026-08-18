#!/usr/bin/env bash
set -euo pipefail
# 一键安装冒烟:隔离目录真实执行 install.sh(上游最新 node LTS + 官方 dsh),
# 完整走 install → 幂等重跑 → 守护(引导页/唤醒/透传/空闲自停)。
# 用法: bash scripts/smoke-test.sh [install.sh 路径]
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL="${1:-$ROOT/scripts/install.sh}"
[ -f "$INSTALL" ] || { echo "找不到 install.sh" >&2; exit 1; }
SMOKE_ROOT="${SMOKE_ROOT:-$(mktemp -d /tmp/dsh-install-smoke.XXXXXX)}"
SMOKE_PORT="${SMOKE_PORT:-13980}"
export DSH_RT_HOME="$SMOKE_ROOT/rt" DSH_RT_STATE="$SMOKE_ROOT/state"
export DSH_HOME="$SMOKE_ROOT/home" DSH_RT_PORT="$SMOKE_PORT" DSH_INSTALL_NO_AGENT=1
RT_HOME="$DSH_RT_HOME"; RT_STATE="$DSH_RT_STATE"
fail() { echo "FAIL: $*" >&2; exit 1; }
step() { echo; echo "== $* =="; }

step "1/4 install(真实安装:node 最新 LTS + dsh latest)"
bash "$INSTALL" || fail "install"
[ -x "$RT_HOME/daemon" ] || fail "daemon 未安装"
[ -f "$SMOKE_ROOT/rt/run.json" ] || fail "run.json 缺失"
grep -q '"node"' "$SMOKE_ROOT/rt/run.json" || fail "run.json 缺 node"
grep -q '"dsh"' "$SMOKE_ROOT/rt/run.json" || fail "run.json 缺 dsh"

step "2/4 幂等重跑(已装同版应秒过)"
time bash "$INSTALL" || fail "重跑 install"

step "3/4 守护:引导页/唤醒/透传"
DSH_RT_IDLE_STOP_SECS=3 "$RT_HOME/daemon" >"$SMOKE_ROOT/daemon.log" 2>&1 &
DAEMON_PID=$!
trap 'kill "$DAEMON_PID" 2>/dev/null || true' EXIT
for i in $(seq 1 50); do
  curl -fsS -o /dev/null "http://127.0.0.1:$SMOKE_PORT/health" 2>/dev/null && break
  sleep 0.2
done
curl -fsS "http://127.0.0.1:$SMOKE_PORT/" | grep -q "DeepSeek Harness" || fail "引导页异常"
curl -fsS "http://127.0.0.1:$SMOKE_PORT/manifest.webmanifest" | grep -q '"display"' || fail "manifest 异常"
h="$(curl -fsS "http://127.0.0.1:$SMOKE_PORT/health")"
echo "$h" | grep -q '"dsh":false' || fail "health 应显示 dsh 未运行: $h"
curl -fsS -X POST "http://127.0.0.1:$SMOKE_PORT/wake" >/dev/null || fail "/wake"
for i in $(seq 1 180); do
  curl -fsS "http://127.0.0.1:$SMOKE_PORT/health" | grep -q '"dsh":true' && break
  sleep 1
done
curl -fsS "http://127.0.0.1:$SMOKE_PORT/health" | grep -q '"dsh":true' || fail "wake 后 dsh 未就绪"
code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$SMOKE_PORT/")"
[ "$code" = "200" ] || fail "透传 UI 返回 $code"
echo "OK: 引导页 + 唤醒 + 透传通过"

step "4/4 空闲自停(PWA 关闭即停止 dsh,DSH_RT_IDLE_STOP_SECS=3)"
sleep 8
curl -fsS "http://127.0.0.1:$SMOKE_PORT/health" | grep -q '"dsh":false' || fail "空闲后 dsh 未自动停止"
echo "OK: 空闲自停通过"
kill "$DAEMON_PID" 2>/dev/null || true
echo; echo "SMOKE OK (root=$SMOKE_ROOT)"