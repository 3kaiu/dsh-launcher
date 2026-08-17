#!/bin/bash
# dshctl —— DeepSeek Harness 运行时管理器(零配置启动器)
# 引导:无运行时 node 时自动下载 nodejs.org 最新 LTS(一次性,SHA-256 校验),
#       之后全部由 dshctl 自动管理(上游新版自动升级)。
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
RT_HOME="${DSH_RT_HOME:-$HOME/.local/share/dsh-runtime}"
RT_NODE="$RT_HOME/node/bin/node"
ARCH="$(uname -m | sed "s/x86_64/x64/")"
if [ ! -x "$RT_NODE" ]; then
  echo "首次使用:自动下载 Node 最新 LTS (darwin-$ARCH) ..."
  VER="$(curl -fsS --max-time 15 https://nodejs.org/dist/index.json | python3 -c 'import json,sys;d=json.load(sys.stdin);print(next((e["version"].lstrip("v") for e in d if e.get("lts") is not False),""))' 2>/dev/null || true)"
  [ -n "$VER" ] || VER="24.19.0"
  TMP="$(mktemp -d /tmp/dshctl-boot.XXXXXX)"
  curl -fSL --max-time 900 -o "$TMP/node-v$VER-darwin-$ARCH.tar.gz" "https://nodejs.org/dist/v$VER/node-v$VER-darwin-$ARCH.tar.gz"
  curl -fsS --max-time 60 -o "$TMP/SHASUMS256.txt" "https://nodejs.org/dist/v$VER/SHASUMS256.txt"
  ( cd "$TMP" && grep "  node-v$VER-darwin-$ARCH.tar.gz$" SHASUMS256.txt | shasum -a 256 -c - >/dev/null )
  mkdir -p "$RT_HOME"
  rm -rf "$RT_HOME/node"
  mkdir -p "$RT_HOME/node"
  tar -xzf "$TMP/node-v$VER-darwin-$ARCH.tar.gz" -C "$RT_HOME/node" --strip-components=1
  rm -rf "$TMP"
  printf '{"node":"%s"}\n' "$VER" > "$RT_HOME/versions.json"
  echo "Node v$VER 就绪 ($RT_HOME/node)"
fi
exec "$RT_NODE" "$DIR/dshctl.ts" "$@"
