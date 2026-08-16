#!/usr/bin/env bash
set -euo pipefail
# dsh-launcher 冒烟测试:在隔离目录真实安装 Node + 官方 dsh,
# 完整走一遍 install → doctor → start → status → HTTP → 幂等 → stop。
# 用法: bash scripts/smoke-test.sh
# 环境变量: SMOKE_ROOT / SMOKE_PORT / DSH_RT_NODE_VERSION / DSH_RT_DSH_VERSION

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DSHCTL="$ROOT/dshctl"
SMOKE_ROOT="${SMOKE_ROOT:-$(mktemp -d /tmp/dsh-launcher-smoke.XXXXXX)}"
SMOKE_PORT="${SMOKE_PORT:-13980}"

export DSH_RT_HOME="$SMOKE_ROOT/rt"
export DSH_RT_STATE="$SMOKE_ROOT/state"
export DSH_HOME="$SMOKE_ROOT/home"
export DSH_RT_PORT="$SMOKE_PORT"
export DSH_RT_NO_OPEN=1
export DSH_RT_NODE_VERSION="${DSH_RT_NODE_VERSION:-24.19.0}"
export DSH_RT_DSH_VERSION="${DSH_RT_DSH_VERSION:-0.1.0-rc.6}"

fail() { echo "FAIL: $*" >&2; exit 1; }
step() { echo; echo "== $* =="; }

step "1/7 install (Node $DSH_RT_NODE_VERSION + dsh $DSH_RT_DSH_VERSION)"
"$DSHCTL" install || fail "install"

step "2/7 doctor"
"$DSHCTL" doctor

step "3/7 start(首次启动,等待就绪)"
"$DSHCTL" start || fail "start"

step "4/7 status(应返回 0)"
"$DSHCTL" status || fail "status"

step "5/7 HTTP 检查"
code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$SMOKE_PORT/")"
[ "$code" = "200" ] || fail "HTTP 返回 $code"
curl -s "http://127.0.0.1:$SMOKE_PORT/manifest.webmanifest" | grep -q '"display": "fullscreen"' \
  || fail "manifest 缺少 display: fullscreen"
echo "OK: / 返回 200,manifest 含 display: fullscreen"

step "6/7 幂等 start(应直接识别已运行)"
"$DSHCTL" start || fail "二次 start"

step "7/7 stop 与端口释放"
"$DSHCTL" stop || fail "stop"
if curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$SMOKE_PORT/"; then
  fail "stop 后端口仍响应"
fi
echo "OK: 端口已释放"

echo
echo "SMOKE OK (root=$SMOKE_ROOT)"
