#!/usr/bin/env bash
set -euo pipefail
# dsh-pwa 一键安装:运行时(node 复用系统或装最新 LTS + 官方 dsh@latest)+ 守护 + LaunchAgent。
# 用法:  bash install.sh          (仓库根 / 发行包根;包内含预编译 daemon 则免 clang)
# 升级:  重跑本脚本即自动跟随上游最新(已安装版本不变则跳过)
# 环境:  DSH_RT_HOME DSH_RT_STATE DSH_HOME DSH_RT_PORT(默认 3080)
#        DSH_INSTALL_NO_AGENT(不注册守护,测试用) DSH_RT_NO_SYSTEM_NODE(强制装自带 node LTS)
START_TS="$(date +%s)"

# 进度输出:仅 TTY 时着色;管道/重定向退化为纯文本,curl 进度条同步切换
if [ -t 1 ]; then
  B=$'\033[1m'; C=$'\033[1;36m'; G=$'\033[32m'; D=$'\033[2m'; Y=$'\033[33m'; R=$'\033[0m'; PB='-#'
else
  B=""; C=""; G=""; D=""; Y=""; R=""; PB='-sS'
fi
h1()   { echo "${C}==>${R} ${B}$*${R}"; }
ok()   { echo "  ${G}✓${R} ${D}$*${R}"; }
warn() { echo "  ${Y}!${R} ${D}$*${R}" >&2; }
h1 "dsh-pwa 安装器"
echo "  ${D}github.com/3kaiu/dsh-pwa${R}"

ROOT="$(cd "$(dirname "$0")" && pwd)"
# 仓库内运行(scripts/install.sh)时回溯到仓库根;发行包内运行时本身就是包根
[ -d "$ROOT/../scripts" ] && ROOT="$(cd "$ROOT/.." && pwd)"
# curl ... | bash 场景:无本地伴随文件 → 自动下载最新发行包到临时目录(无需手动下载)
if [ ! -f "$ROOT/src/daemon.c" ] && [ ! -f "$ROOT/daemon" ]; then
  h1 "自动下载发行包(releases/latest)"
  PKG_TMP="$(mktemp -d /tmp/dsh-pwa.XXXXXX)"
  curl -fsSL --max-time 300 -o "$PKG_TMP/pkg.zip" \
    "https://github.com/3kaiu/dsh-pwa/releases/latest/download/dsh-pwa.zip" \
    || { echo "发行包下载失败(仓库尚无 release?)" >&2; exit 1; }
  KB="$(awk -v n="$(stat -f%z "$PKG_TMP/pkg.zip")" 'BEGIN{printf "%.1f", n/1024}')"
  ( cd "$PKG_TMP" && unzip -q pkg.zip )
  rm -f "$PKG_TMP/pkg.zip"
  ROOT="$PKG_TMP"
  ok "发行包 ${KB} KB 下载解压完成"
fi
RT_HOME="${DSH_RT_HOME:-$HOME/.local/share/dsh-runtime}"
RT_STATE="${DSH_RT_STATE:-$HOME/.local/state/dsh-runtime}"
DSH_HOME="${DSH_HOME:-$HOME/.dsh}"
PORT="${DSH_RT_PORT:-3080}"
LOG_DIR="$RT_STATE/logs"
NODE_DIR="$RT_HOME/node"
APP_DIR="$RT_HOME/app"
NODE_BIN="$NODE_DIR/bin/node"
NPM_BIN="$NODE_DIR/bin/npm"
DSH_PKG="$APP_DIR/node_modules/@deepseek-ai/dsh/package.json"
ARCH="$(uname -m | sed 's/x86_64/x64/')"
mkdir -p "$RT_HOME" "$RT_STATE" "$LOG_DIR" "$NODE_DIR" "$APP_DIR" "$DSH_HOME"

# 安装锁(并发互斥:双击连点/重复安装时后到者等待;仅属主进程已死才可抢占——
# 旧逻辑按 10 分钟锁龄抢占活锁,慢网首装实测 >12 分钟,会导致两个安装互相破坏)
LOCK="$RT_HOME/.install.lock"
LOCKED=0
for i in $(seq 1 300); do
  if mkdir "$LOCK" 2>/dev/null; then
    echo "$$" > "$LOCK/pid"; LOCKED=1; break
  fi
  LPID="$(cat "$LOCK/pid" 2>/dev/null || true)"
  if [ -z "$LPID" ] || ! kill -0 "$LPID" 2>/dev/null; then
    rm -rf "$LOCK"; continue
  fi
  sleep 1
done
[ "$LOCKED" = "1" ] || { echo "等待安装锁超时(300s),请稍后重试" >&2; exit 1; }
trap 'rm -f "$LOCK/pid"; rmdir "$LOCK" 2>/dev/null || true; [ -n "${PKG_TMP:-}" ] && rm -rf "$PKG_TMP"' EXIT

# ---------- 1) Node:优先复用系统已有 node(fnm/volta/nvm/PATH 均可,>=22 且带 npm);
#                否则安装 nodejs.org 最新 LTS(DSH_RT_NO_SYSTEM_NODE=1 强制走此路径) ----------
MIN_NODE=22
SYS_NODE=""; SYS_NPM=""
if [ -z "${DSH_RT_NO_SYSTEM_NODE:-}" ]; then
  CAND="$(command -v node 2>/dev/null || true)"
  if [ -n "$CAND" ]; then
    # 解析 fnm/volta 等 shim 符号链接到真实二进制(fnm 的 multishell 临时目录会随 shell 退出失效)
    CAND="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$CAND" 2>/dev/null || echo "$CAND")"
    V="$("$CAND" --version 2>/dev/null | sed 's/^v//' || true)"
    M="${V%%.*}"
    if [ -n "$M" ] && [ "$M" -ge "$MIN_NODE" ]; then
      CAND_NPM="$(dirname "$CAND")/npm"
      if [ -x "$CAND_NPM" ]; then
        SYS_NODE="$CAND"; SYS_NPM="$CAND_NPM"
      elif command -v npm >/dev/null 2>&1; then
        SYS_NODE="$CAND"; SYS_NPM="$(command -v npm)"
      fi
    fi
  fi
fi
if [ -n "$SYS_NODE" ]; then
  NODE_BIN="$SYS_NODE"; NPM_BIN="$SYS_NPM"
  CUR_VER="$("$NODE_BIN" --version 2>/dev/null | sed 's/^v//' || true)"
  h1 "1) Node 运行时(复用系统 node v$CUR_VER)"
  ok "$NODE_BIN"
  # 此前安装过的自带 node 不再需要,腾出空间
  [ -x "$NODE_DIR/bin/node" ] && [ "$NODE_DIR/bin/node" != "$SYS_NODE" ] && rm -rf "$NODE_DIR"
else
  h1 "1) Node 运行时(nodejs.org 最新 LTS)"
  LTS_VER="$(curl -fsS --max-time 15 https://nodejs.org/dist/index.json 2>/dev/null \
    | python3 -c 'import json,sys;d=json.load(sys.stdin);print(next((e["version"].lstrip("v") for e in d if e.get("lts") is not False),""))' 2>/dev/null || true)"
  [ -n "$LTS_VER" ] || LTS_VER="24.19.0"
  CUR_VER="$("$NODE_BIN" --version 2>/dev/null | sed 's/^v//' || true)"
  if [ "$CUR_VER" != "$LTS_VER" ]; then
    CACHE="$RT_HOME/.cache"; mkdir -p "$CACHE"
    TAR="$CACHE/node-v$LTS_VER-darwin-$ARCH.tar.gz"
    if [ ! -f "$TAR" ]; then
      echo "  ${D}下载 node-v$LTS_VER-darwin-$ARCH.tar.gz ...${R}"
      curl -fSL $PB --max-time 900 -o "$TAR" "https://nodejs.org/dist/v$LTS_VER/node-v$LTS_VER-darwin-$ARCH.tar.gz"
    fi
    # 校验 fail-closed:拿不到 SHASUMS 也中止,绝不安装未校验的二进制
    curl -fsS --max-time 60 -o "$CACHE/SHASUMS256.txt" "https://nodejs.org/dist/v$LTS_VER/SHASUMS256.txt" 2>/dev/null \
      || { warn "SHASUMS256.txt 下载失败,无法校验 node 安装包"; rm -f "$TAR"; exit 1; }
    ( cd "$CACHE" && grep "  node-v$LTS_VER-darwin-$ARCH.tar.gz$" SHASUMS256.txt | shasum -a 256 -c - >/dev/null ) \
      || { warn "SHA-256 校验失败"; rm -f "$TAR"; exit 1; }
    TMP="$(mktemp -d /tmp/dsh-install.XXXXXX)"
    tar -xzf "$TAR" -C "$TMP" --strip-components=1
    rm -rf "$NODE_DIR"
    mkdir -p "$NODE_DIR/bin" "$NODE_DIR/lib/node_modules"
    cp -P "$TMP/bin/node" "$NODE_DIR/bin/node"
    cp -P "$TMP/bin/npm" "$NODE_DIR/bin/npm"
    cp -R "$TMP/lib/node_modules/npm" "$NODE_DIR/lib/node_modules/"
    chmod +x "$NODE_DIR/bin/node" "$NODE_DIR/bin/npm"
    # strip 符号表再瘦 ~23MB;strip 使原签名失效,立即 ad-hoc 重签
    if ! strip -x "$NODE_DIR/bin/node" 2>/dev/null || ! codesign --force -s - "$NODE_DIR/bin/node" 2>/dev/null; then
      cp -P "$TMP/bin/node" "$NODE_DIR/bin/node"
    fi
    rm -rf "$TMP"
    ok "Node v$LTS_VER 安装完成"
  else
    ok "已是最新 v$CUR_VER,跳过"
  fi
fi

# ---------- 2) dsh:npm 官方 @deepseek-ai/dsh@latest(已装且同版则跳过) ----------
h1 "2) dsh(@deepseek-ai/dsh@latest)"
LATEST="$(curl -fsS --max-time 15 https://registry.npmjs.org/@deepseek-ai/dsh/latest 2>/dev/null \
  | python3 -c 'import json,sys;print(json.load(sys.stdin)["version"])' 2>/dev/null || true)"
CUR_DSH="$("$NODE_BIN" -e 'console.log(require(process.argv[1]).version)' "$DSH_PKG" 2>/dev/null || true)"
if [ -n "$LATEST" ] && [ "$CUR_DSH" != "$LATEST" ] || [ -z "$CUR_DSH" ]; then
  # 装显式版本号,绕开 npm 本地缓存把 latest 解析成旧版
  printf '{"name":"dsh-runtime-app","private":true,"dependencies":{"@deepseek-ai/dsh":"%s"}}\n' "${LATEST:-latest}" > "$APP_DIR/package.json"
  # 发行包含预解析的 package-lock.json → npm install 跳过依赖解析,省 30~60s
  [ -f "$ROOT/package-lock.json" ] && cp "$ROOT/package-lock.json" "$APP_DIR/"
  # npm 自带进度/报错,无需额外包装;同时去除 python3 硬依赖(全新 macOS 无 python3 会卡安装)
  echo "  ${D}npm install dsh@${LATEST:-latest}(451 个依赖,首次约 3~10 分钟视网络)${R}"
  NPM_START="$SECONDS"
  if ! PATH="$NODE_DIR/bin:$PATH" NODE_OPTIONS="--max-old-space-size=4096" "$NPM_BIN" install --prefer-offline --no-audit --no-fund --prefix "$APP_DIR"; then
    warn "dsh 安装失败"
    exit 1
  fi
  ok "npm install 完成($(( SECONDS - NPM_START ))s)"
  # 剪除 sourcemap/文档/测试(运行时永不加载,纯占空间)
  find "$APP_DIR/node_modules" \( -name "*.map" -o -name "*.md" -o -name ".DS_Store" \) -delete 2>/dev/null || true
  find "$APP_DIR/node_modules" -type d \( -name test -o -name tests -o -name __tests__ \) -exec rm -rf {} + 2>/dev/null || true
  CUR_DSH="$("$NODE_BIN" -e 'console.log(require(process.argv[1]).version)' "$DSH_PKG")"
  ok "dsh $CUR_DSH 安装完成"
else
  ok "已是最新 $CUR_DSH,跳过"
fi

# ---------- 3) run.json:守护直启 dsh 的运行时位置(单一事实源) ----------
h1 "3) 运行时配置(run.json)"
DSH_BIN="$("$NODE_BIN" -e '
  const { join, dirname } = require("path");
  const p = process.argv[1];
  const pkg = require(p);
  const bin = typeof pkg.bin === "string" ? pkg.bin : (pkg.bin && pkg.bin.dsh) || "lib/bin.js";
  console.log(join(dirname(p), bin));
' "$DSH_PKG")"
"$NODE_BIN" -e '
  const fs = require("fs");
  fs.writeFileSync(process.argv[1], JSON.stringify({ node: process.argv[2], dsh: process.argv[3] }) + "\n");
' "$RT_HOME/run.json" "$NODE_BIN" "$DSH_BIN"
ok "node=$NODE_BIN"
ok "dsh=$DSH_BIN"

# ---------- 4) 守护二进制(发行包预编译优先;否则本地 clang 编译;均 ad-hoc 签名) ----------
h1 "4) 守护(常驻唤醒,~1.3MB RSS)"
install_daemon() { chmod +x "$RT_HOME/daemon"; codesign --force -s - "$RT_HOME/daemon" 2>/dev/null || true; }
if [ -x "$ROOT/daemon" ] && [ "$(file -b "$ROOT/daemon" | grep -c "$(uname -m)")" = "1" ]; then
  cp "$ROOT/daemon" "$RT_HOME/daemon"; install_daemon
  ok "发行包预编译($(uname -m))"
elif [ -f "$ROOT/src/daemon.c" ] && command -v clang >/dev/null; then
  SRC_MD5="$(md5 -q "$ROOT/src/daemon.c" 2>/dev/null || true)"
  if [ -x "$RT_HOME/daemon" ] && [ "$SRC_MD5" != "" ] && [ "$SRC_MD5" = "$(cat "$RT_HOME/.daemon.md5" 2>/dev/null || true)" ]; then
    install_daemon
    ok "守护已是最新(daemon.c 未变,免编译)"
  else
    echo "  ${D}clang 编译中 ...${R}"
    clang -O2 -Wall -Wextra -o "$RT_HOME/daemon" "$ROOT/src/daemon.c" || { warn "守护编译失败"; exit 1; }
    [ -n "$SRC_MD5" ] && printf '%s\n' "$SRC_MD5" > "$RT_HOME/.daemon.md5"
    install_daemon
    ok "本地 clang 编译完成"
  fi
elif [ -x "$RT_HOME/daemon" ]; then
  ok "沿用已安装"
else
  warn "未找到可用守护(需预编译 daemon 或 clang),PWA 自动拉起不可用"
fi

# ---------- 5) LaunchAgent 注册(登录即常驻,1.3MB) ----------
h1 "5) LaunchAgent(登录即常驻)"
AGENT_OK=0
if [ -z "${DSH_INSTALL_NO_AGENT:-}" ]; then
  TPL="$ROOT/launchd/com.dshpwa.daemon.plist"
  [ -f "$TPL" ] || TPL="$ROOT/com.dshpwa.daemon.plist"
  if [ -f "$TPL" ]; then
    AGENT_DIR="$HOME/Library/LaunchAgents"
    AGENT="$AGENT_DIR/com.dshpwa.daemon.plist"
    mkdir -p "$AGENT_DIR"
    sed -e "s|__DAEMON_BIN__|$RT_HOME/daemon|g" \
        -e "s|__HOME__|$HOME|g" \
        -e "s|__RT_HOME__|$RT_HOME|g" \
        -e "s|__RT_STATE__|$RT_STATE|g" \
        -e "s|__LOG_DIR__|$LOG_DIR|g" \
        -e "s|__DSH_RT_PORT__|$PORT|g" "$TPL" > "$AGENT"
    # 清理旧名残留(改名前的 com.dshlauncher.daemon),避免旧守护占住端口
    launchctl bootout "gui/$(id -u)/com.dshlauncher.daemon" 2>/dev/null || true
    rm -f "$AGENT_DIR/com.dshlauncher.daemon.plist"
    launchctl bootstrap "gui/$(id -u)" "$AGENT" 2>/dev/null \
      || launchctl enable "gui/$(id -u)/com.dshpwa.daemon" 2>/dev/null || true
    launchctl kickstart -k "gui/$(id -u)/com.dshpwa.daemon" 2>/dev/null || true
    AGENT_OK=1
    ok "com.dshpwa.daemon 已注册并启动"
  else
    warn "缺少 plist 模板,未注册守护"
  fi
else
  ok "跳过(DSH_INSTALL_NO_AGENT)"
fi

# ---------- 6) 完成:自动打开 dsh 页面 ----------
SECS=$(( $(date +%s) - START_TS ))
echo
echo "${G}✓${R} ${B}安装完成${R}(${D}${SECS}s${R})"
echo "  ${D}node v$("$NODE_BIN" --version 2>/dev/null | sed 's/^v//' || echo -) · dsh $CUR_DSH · 运行时 $RT_HOME${R}"
if [ "$AGENT_OK" = "1" ]; then
  open "http://127.0.0.1:$PORT/" 2>/dev/null || true
  echo "  ${D}已自动打开 http://127.0.0.1:$PORT/${R}"
fi
