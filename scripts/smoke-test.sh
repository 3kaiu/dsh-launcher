#!/usr/bin/env bash
set -euo pipefail
# dshctl 便携包冒烟:隔离目录真实安装上游最新 Node + 官方 dsh(动态版本,不写死),
# 完整走 install → doctor → start → status → HTTP → 幂等 → stop。
# 用法: bash scripts/smoke-test.sh [dshctl路径]
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DSHCTL="${1:-$ROOT/dist/stage/dshctl}"
[ -x "$DSHCTL" ] || { echo "先构建: node scripts/release.ts dev arm64" >&2; exit 1; }
SMOKE_ROOT="${SMOKE_ROOT:-$(mktemp -d /tmp/dshctl-smoke.XXXXXX)}"
SMOKE_PORT="${SMOKE_PORT:-13980}"
export DSH_RT_HOME="$SMOKE_ROOT/rt" DSH_RT_STATE="$SMOKE_ROOT/state"
export DSH_HOME="$SMOKE_ROOT/home" DSH_RT_PORT="$SMOKE_PORT" DSHCTL_NO_OPEN=1
fail() { echo "FAIL: $*" >&2; exit 1; }
step() { echo; echo "== $* =="; }
step "1/7 install(动态:上游最新 node LTS + dsh latest)"
"$DSHCTL" install || fail "install"
step "2/7 doctor"
"$DSHCTL" doctor || fail "doctor"
step "3/7 start(首次启动,等待就绪)"
"$DSHCTL" start || fail "start"
step "4/7 status(应返回 0)"
"$DSHCTL" status || fail "status"
step "5/7 HTTP 检查"
code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$SMOKE_PORT/")"
[ "$code" = "200" ] || fail "HTTP 返回 $code"
curl -s "http://127.0.0.1:$SMOKE_PORT/manifest.webmanifest" | grep -q '"display"' || fail "manifest 异常"
echo "OK: / 返回 200"
step "6/7 幂等 start"
"$DSHCTL" start || fail "二次 start"
step "7/7 stop 与端口释放"
"$DSHCTL" stop || fail "stop"
if curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$SMOKE_PORT/"; then fail "stop 后端口仍响应"; fi
echo "OK: 端口已释放"
echo; echo "SMOKE OK (root=$SMOKE_ROOT)"
