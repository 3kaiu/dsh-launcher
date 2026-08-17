#!/bin/bash
# dshctl —— DeepSeek Harness 运行时管理器(零配置启动器)
# 引导:优先用包内自带运行时(精简 node + 预装 dsh,构建时已装好,双击即用零下载);
#       无包内运行时(命令行便携包)时自动下载 nodejs.org 最新 LTS(SHA-256 校验)并 npm 安装 dsh。
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
RT_HOME="${DSH_RT_HOME:-$HOME/.local/share/dsh-runtime}"
RT_NODE="$RT_HOME/node/bin/node"
BUNDLED_NODE="$DIR/node/bin/node"
BUNDLED_APP="$DIR/app"
ARCH="$(uname -m | sed "s/x86_64/x64/")"
NODE_VER=""
DSH_VER=""

# 并发安装锁(与 dshctl.ts 同一把锁):首次安装/引导互斥,双击连点或 CLI 并发时后到者等待
LOCK="$RT_HOME/.bootstrap.lock"
mkdir -p "$RT_HOME" 2>/dev/null || true
LOCKED=0
for i in $(seq 1 300); do
  if mkdir "$LOCK" 2>/dev/null; then
    echo "$$" > "$LOCK/pid"
    LOCKED=1
    break
  fi
  LPID="$(cat "$LOCK/pid" 2>/dev/null || echo 0)"
  # 仅当 pid 为数字且进程已死才判定失效;空 pid(持锁方尚未写入)只等待
  if [ "$LPID" != "0" ] && ! kill -0 "$LPID" 2>/dev/null; then rm -rf "$LOCK"; continue; fi
  sleep 1
done
if [ "$LOCKED" != "1" ]; then echo "等待安装锁超时(300s),请稍后重试" >&2; exit 1; fi
trap '[ "$LOCKED" = "1" ] && { rm -f "$LOCK/pid"; rmdir "$LOCK" 2>/dev/null || true; }' EXIT
release_lock() { [ "$LOCKED" = "1" ] && { rm -f "$LOCK/pid"; rmdir "$LOCK" 2>/dev/null || true; }; }

if [ ! -x "$RT_NODE" ]; then
  if [ -x "$BUNDLED_NODE" ]; then
    NODE_VER="$("$BUNDLED_NODE" --version 2>/dev/null | sed 's/^v//')"
    echo "使用包内 Node v${NODE_VER:-?} 初始化运行时(首次引导)..."
    mkdir -p "$RT_HOME"
    rm -rf "$RT_HOME/node"
    mkdir -p "$RT_HOME/node"
    # APFS 克隆(瞬时)失败则回退普通拷贝
    cp -c -R "$DIR/node/." "$RT_HOME/node/" 2>/dev/null || cp -R "$DIR/node/." "$RT_HOME/node/"
  else
    echo "首次使用:自动下载 Node 最新 LTS (darwin-$ARCH) ..."
    VER="$(curl -fsS --max-time 15 https://nodejs.org/dist/index.json | python3 -c 'import json,sys;d=json.load(sys.stdin);print(next((e["version"].lstrip("v") for e in d if e.get("lts") is not False),""))' 2>/dev/null || true)"
    [ -n "$VER" ] || VER="24.19.0"
    TMP="$(mktemp -d /tmp/dshctl-boot.XXXXXX)"
    mkdir -p "$TMP/x"
    curl -fSL --max-time 900 -o "$TMP/node-v$VER-darwin-$ARCH.tar.gz" "https://nodejs.org/dist/v$VER/node-v$VER-darwin-$ARCH.tar.gz"
    curl -fsS --max-time 60 -o "$TMP/SHASUMS256.txt" "https://nodejs.org/dist/v$VER/SHASUMS256.txt"
    ( cd "$TMP" && grep "  node-v$VER-darwin-$ARCH.tar.gz$" SHASUMS256.txt | shasum -a 256 -c - >/dev/null )
    tar -xzf "$TMP/node-v$VER-darwin-$ARCH.tar.gz" -C "$TMP/x" --strip-components=1
    # 精简:只留 bin/node + bin/npm(符号链接,需 -P)+ lib/node_modules/npm
    mkdir -p "$RT_HOME/node/bin" "$RT_HOME/node/lib/node_modules"
    cp -P "$TMP/x/bin/node" "$RT_HOME/node/bin/node"
    cp -P "$TMP/x/bin/npm" "$RT_HOME/node/bin/npm"
    cp -R "$TMP/x/lib/node_modules/npm" "$RT_HOME/node/lib/node_modules/"
    chmod +x "$RT_HOME/node/bin/node" "$RT_HOME/node/bin/npm"
    rm -rf "$TMP"
    NODE_VER="$VER"
  fi
fi

# 运行时 app(官方 dsh):包内已预装 → 本地拷贝即可,无需 npm 安装
if [ ! -f "$RT_HOME/app/node_modules/@deepseek-ai/dsh/package.json" ]; then
  if [ -f "$BUNDLED_APP/package.json" ] && [ -d "$BUNDLED_APP/node_modules" ]; then
    echo "使用包内已预装的 dsh 运行时(免安装)..."
    rm -rf "$RT_HOME/app"
    cp -c -R "$BUNDLED_APP" "$RT_HOME/app" 2>/dev/null || cp -R "$BUNDLED_APP" "$RT_HOME/app"
    DSH_VER="$("$RT_NODE" -e 'console.log(require(process.argv[1]).version)' "$RT_HOME/app/node_modules/@deepseek-ai/dsh/package.json" 2>/dev/null || true)"
  fi
fi

# 记录本次引导的实际版本(只写有值的项,保留既有记录)
if [ -n "$NODE_VER" ] || [ -n "$DSH_VER" ]; then
  "$RT_NODE" -e '
    const fs = require("fs");
    const f = process.argv[1];
    const d = fs.existsSync(f) ? JSON.parse(fs.readFileSync(f, "utf8")) : {};
    if (process.argv[2]) d.node = process.argv[2];
    if (process.argv[3]) d.dsh = process.argv[3];
    fs.writeFileSync(f, JSON.stringify(d) + "\n");
  ' "$RT_HOME/versions.json" "$NODE_VER" "$DSH_VER"
fi
release_lock
exec "$RT_NODE" "$DIR/dshctl.ts" "$@"