#!/usr/bin/env bash
set -euo pipefail
# dsh-launcher 一键安装:运行时(node 最新 LTS + 官方 dsh@latest)+ 守护 + LaunchAgent。
# 用法:  bash install.sh          (仓库根 / 发行包根;包内含预编译 daemon 则免 clang)
# 升级:  重跑本脚本即自动跟随上游最新(已安装版本不变则跳过)
# 环境:  DSH_RT_HOME DSH_RT_STATE DSH_HOME DSH_RT_PORT(默认 3080) DSH_INSTALL_NO_AGENT(不注册守护,测试用)
ROOT="$(cd "$(dirname "$0")" && pwd)"
# 仓库内运行(scripts/install.sh)时回溯到仓库根;发行包内运行时本身就是包根
[ -d "$ROOT/../scripts" ] && ROOT="$(cd "$ROOT/.." && pwd)"
# curl ... | bash 场景:无本地伴随文件 → 自动下载最新发行包到临时目录(无需手动下载)
if [ ! -f "$ROOT/src/daemon.c" ] && [ ! -f "$ROOT/daemon" ]; then
  echo "== 自动下载发行包(dsh-launcher/releases/latest) =="
  TMP="$(mktemp -d /tmp/dsh-launcher.XXXXXX)"
  curl -fSL --max-time 300 -o "$TMP/pkg.zip" \
    "https://github.com/3kaiu/dsh-pwa/releases/latest/download/dsh-launcher.zip" \
    || { echo "发行包下载失败(仓库尚无 release?)" >&2; exit 1; }
  ( cd "$TMP" && unzip -q pkg.zip )
  rm -f "$TMP/pkg.zip"
  ROOT="$TMP"
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

# 安装锁(并发互斥:双击连点/重复安装时后到者等待)
LOCK="$RT_HOME/.install.lock"
LOCKED=0
for i in $(seq 1 300); do
  if mkdir "$LOCK" 2>/dev/null; then
    echo "$$" > "$LOCK/pid"; LOCKED=1; break
  fi
  LPID="$(cat "$LOCK/pid" 2>/dev/null || echo 0)"
  if [ "$LPID" != "0" ] && ! kill -0 "$LPID" 2>/dev/null; then rm -rf "$LOCK"; continue; fi
  sleep 1
done
[ "$LOCKED" = "1" ] || { echo "等待安装锁超时(300s),请稍后重试" >&2; exit 1; }
trap 'rm -f "$LOCK/pid"; rmdir "$LOCK" 2>/dev/null || true' EXIT

# ---------- 1) Node:nodejs.org 最新 LTS(已装且同版则跳过) ----------
LTS_VER="$(curl -fsS --max-time 15 https://nodejs.org/dist/index.json 2>/dev/null \
  | python3 -c 'import json,sys;d=json.load(sys.stdin);print(next((e["version"].lstrip("v") for e in d if e.get("lts") is not False),""))' 2>/dev/null || true)"
[ -n "$LTS_VER" ] || LTS_VER="24.19.0"
CUR_VER="$("$NODE_BIN" --version 2>/dev/null | sed 's/^v//' || true)"
if [ "$CUR_VER" != "$LTS_VER" ]; then
  echo "== 安装 Node v$LTS_VER (darwin-$ARCH) =="
  CACHE="$RT_HOME/.cache"; mkdir -p "$CACHE"
  TAR="$CACHE/node-v$LTS_VER-darwin-$ARCH.tar.gz"
  if [ ! -f "$TAR" ]; then
    curl -fSL --max-time 900 -o "$TAR" "https://nodejs.org/dist/v$LTS_VER/node-v$LTS_VER-darwin-$ARCH.tar.gz"
  fi
  if curl -fsS --max-time 60 -o "$CACHE/SHASUMS256.txt" "https://nodejs.org/dist/v$LTS_VER/SHASUMS256.txt" 2>/dev/null; then
    ( cd "$CACHE" && grep "  node-v$LTS_VER-darwin-$ARCH.tar.gz$" SHASUMS256.txt | shasum -a 256 -c - >/dev/null ) \
      || { echo "SHA-256 校验失败" >&2; rm -f "$TAR"; exit 1; }
  fi
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
  echo "   Node v$LTS_VER 安装完成"
fi

# ---------- 2) dsh:npm 官方 @deepseek-ai/dsh@latest(已装且同版则跳过) ----------
LATEST="$(curl -fsS --max-time 15 https://registry.npmjs.org/@deepseek-ai/dsh/latest 2>/dev/null \
  | python3 -c 'import json,sys;print(json.load(sys.stdin)["version"])' 2>/dev/null || true)"
CUR_DSH="$("$NODE_BIN" -e 'console.log(require(process.argv[1]).version)' "$DSH_PKG" 2>/dev/null || true)"
if [ -n "$LATEST" ] && [ "$CUR_DSH" != "$LATEST" ] || [ -z "$CUR_DSH" ]; then
  echo "== 安装官方 dsh@${LATEST:-latest} =="
  printf '{"name":"dsh-runtime-app","private":true,"dependencies":{"@deepseek-ai/dsh":"latest"}}\n' > "$APP_DIR/package.json"
  PATH="$NODE_DIR/bin:$PATH" "$NPM_BIN" install --no-audit --no-fund --loglevel=error --prefix "$APP_DIR" >/dev/null
  # 剪除运行时永不加载的 sourcemap/文档/测试 与遥测/零引用依赖
  find "$APP_DIR/node_modules" \( -name "*.map" -o -name "*.md" -o -name ".DS_Store" \) -delete 2>/dev/null || true
  find "$APP_DIR/node_modules" -type d \( -name test -o -name tests -o -name __tests__ \) -exec rm -rf {} + 2>/dev/null || true
  rm -rf "$APP_DIR/node_modules/@opentelemetry" \
         "$APP_DIR/node_modules/@deepseek-ai/dsh-session-telemetry-otel" \
         "$APP_DIR/node_modules/mistralai" 2>/dev/null || true
  CUR_DSH="$("$NODE_BIN" -e 'console.log(require(process.argv[1]).version)' "$DSH_PKG")"
  echo "   dsh $CUR_DSH 安装完成"
fi

# ---------- 3) run.json:守护直启 dsh 的运行时位置(单一事实源) ----------
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
echo "   run.json: node=$NODE_BIN / dsh=$DSH_BIN"

# ---------- 4) 守护二进制(发行包预编译优先;否则本地 clang 编译;均 ad-hoc 签名) ----------
install_daemon() { chmod +x "$RT_HOME/daemon"; codesign --force -s - "$RT_HOME/daemon" 2>/dev/null || true; }
if [ -x "$ROOT/daemon" ] && [ "$(file -b "$ROOT/daemon" | grep -c "$(uname -m)")" = "1" ]; then
  echo "== 安装守护(发行包预编译) =="
  cp "$ROOT/daemon" "$RT_HOME/daemon"; install_daemon
elif [ -f "$ROOT/src/daemon.c" ] && command -v clang >/dev/null; then
  echo "== 编译守护(本地 clang) =="
  clang -O2 -Wall -Wextra -o "$RT_HOME/daemon" "$ROOT/src/daemon.c" || { echo "守护编译失败" >&2; exit 1; }
  install_daemon
elif [ -x "$RT_HOME/daemon" ]; then
  echo "== 守护:沿用已安装 =="
else
  echo "警告: 找不到可用的守护(需要预编译 daemon 或 clang),PWA 自动拉起不可用" >&2
fi

# ---------- 5) LaunchAgent 注册(登录即常驻,1.3MB) ----------
if [ -z "${DSH_INSTALL_NO_AGENT:-}" ]; then
  TPL="$ROOT/launchd/com.dshlauncher.daemon.plist"
  [ -f "$TPL" ] || TPL="$ROOT/com.dshlauncher.daemon.plist"
  if [ -f "$TPL" ]; then
    echo "== 注册守护(LaunchAgent) =="
    AGENT_DIR="$HOME/Library/LaunchAgents"
    AGENT="$AGENT_DIR/com.dshlauncher.daemon.plist"
    mkdir -p "$AGENT_DIR"
    sed -e "s|__DAEMON_BIN__|$RT_HOME/daemon|g" \
        -e "s|__RT_HOME__|$RT_HOME|g" \
        -e "s|__RT_STATE__|$RT_STATE|g" \
        -e "s|__LOG_DIR__|$LOG_DIR|g" "$TPL" > "$AGENT"
    launchctl bootstrap "gui/$(id -u)" "$AGENT" 2>/dev/null \
      || launchctl enable "gui/$(id -u)/com.dshlauncher.daemon" 2>/dev/null || true
    launchctl kickstart -k "gui/$(id -u)/com.dshlauncher.daemon" 2>/dev/null || true
  else
    echo "警告: 缺少 plist 模板,未注册守护" >&2
  fi
else
  echo "== 跳过 LaunchAgent 注册(DSH_INSTALL_NO_AGENT) =="
fi

# ---------- 6) 完成 ----------
echo
echo "✓ 安装完成"
echo "  node: $("$NODE_BIN" --version 2>/dev/null || echo -) / dsh: $CUR_DSH"
echo "  运行时: $RT_HOME"
echo
echo "下一步(Safari):"
echo "  1. 打开 http://127.0.0.1:$PORT/  (dsh 未运行时会自动拉起)"
echo "  2. 菜单栏 文件 → 添加到程序坞,以后从 Dock 打开/关闭即自动启停 dsh"
echo "  3. 升级: 重跑本脚本"
