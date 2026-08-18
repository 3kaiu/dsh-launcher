#!/usr/bin/env bash
set -euo pipefail
# dshctl 便携包冒烟:隔离目录真实安装上游最新 Node + 官方 dsh(动态版本,不写死),
# 完整走 install → doctor → start → status → HTTP → 幂等 → stop。
# 用法: bash scripts/smoke-test.sh [dshctl路径]
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DSHCTL="${1:-$ROOT/dist/stage/dshctl}"
[ -x "$DSHCTL" ] || { echo "先构建: node scripts/release.ts dev" >&2; exit 1; }
SMOKE_ROOT="${SMOKE_ROOT:-$(mktemp -d /tmp/dshctl-smoke.XXXXXX)}"
SMOKE_PORT="${SMOKE_PORT:-13980}"
export DSH_RT_HOME="$SMOKE_ROOT/rt" DSH_RT_STATE="$SMOKE_ROOT/state"
export DSH_HOME="$SMOKE_ROOT/home" DSH_RT_PORT="$SMOKE_PORT" DSHCTL_NO_OPEN=1
fail() { echo "FAIL: $*" >&2; exit 1; }
step() { echo; echo "== $* =="; }
step "1/8 install(动态:上游最新 node LTS + dsh latest)"
"$DSHCTL" install || fail "install"
step "2/8 doctor"
"$DSHCTL" doctor || fail "doctor"
step "3/8 start(首次启动,等待就绪)"
"$DSHCTL" start || fail "start"
step "4/8 status(应返回 0)"
"$DSHCTL" status || fail "status"
step "5/8 HTTP 检查"
code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$SMOKE_PORT/")"
[ "$code" = "200" ] || fail "HTTP 返回 $code"
curl -s "http://127.0.0.1:$SMOKE_PORT/manifest.webmanifest" | grep -q '"display"' || fail "manifest 异常"
echo "OK: / 返回 200"
step "6/8 幂等 start"
"$DSHCTL" start || fail "二次 start"
step "7/8 stop 与端口释放"
"$DSHCTL" stop || fail "stop"
if curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$SMOKE_PORT/"; then fail "stop 后端口仍响应"; fi
echo "OK: 端口已释放"
step "8/8 守护唤醒+空闲自停(单端口:PWA 关闭即停止 dsh)"
STAGE="$(dirname "$DSHCTL")"
[ -x "$STAGE/daemon" ] || fail "stage 缺少 daemon 二进制"
DSH_RT_IDLE_STOP_SECS=3 DSH_RT_PORT=$SMOKE_PORT "$STAGE/daemon" >"$SMOKE_ROOT/daemon.log" 2>&1 &
DAEMON_PID=$!
trap 'kill "$DAEMON_PID" 2>/dev/null || true' EXIT
for i in $(seq 1 50); do
  curl -fsS -o /dev/null "http://127.0.0.1:$SMOKE_PORT/health" 2>/dev/null && break
  sleep 0.2
done
curl -fsS "http://127.0.0.1:$SMOKE_PORT/" | grep -q "DeepSeek Harness" || fail "引导页异常"
curl -fsS "http://127.0.0.1:$SMOKE_PORT/manifest.webmanifest" | grep -q '"display"' || fail "守护 manifest 异常"
h="$(curl -fsS "http://127.0.0.1:$SMOKE_PORT/health")"
echo "$h" | grep -q '"dsh":false' || fail "health 应显示 dsh 未运行: $h"
curl -fsS -X POST "http://127.0.0.1:$SMOKE_PORT/wake" >/dev/null || fail "/wake"
for i in $(seq 1 180); do
  curl -fsS "http://127.0.0.1:$SMOKE_PORT/health" | grep -q '"dsh":true' && break
  sleep 1
done
curl -fsS "http://127.0.0.1:$SMOKE_PORT/health" | grep -q '"dsh":true' || fail "wake 后 dsh 未就绪"
curl -fsS "http://127.0.0.1:$SMOKE_PORT/manifest.webmanifest" | grep -q '"display"' || fail "dsh 就绪后透传异常"
echo "OK: 单端口唤醒成功(dsh 内部端口自动匹配)"
# PWA 关闭(连接归零)→ 空闲 3 秒自动停止 dsh
sleep 8
curl -fsS "http://127.0.0.1:$SMOKE_PORT/health" | grep -q '"dsh":false' || fail "空闲后 dsh 未自动停止"
echo "OK: 空闲自停通过(PWA 关闭即停止 dsh)"
kill "$DAEMON_PID" 2>/dev/null || true
echo; echo "SMOKE OK (root=$SMOKE_ROOT)"
