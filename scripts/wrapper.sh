#!/bin/bash
# dshctl —— DeepSeek Harness 运行时管理器(便携包启动器,零配置)
# 包内自带 node;运行时已自动升级则优先用最新运行时 node
DIR="$(cd "$(dirname "$0")" && pwd)"
RT_NODE="$HOME/.local/share/dsh-runtime/node/bin/node"
if [ -x "$RT_NODE" ]; then exec "$RT_NODE" "$DIR/dshctl.mjs" "$@"; fi
exec "$DIR/node/bin/node" "$DIR/dshctl.mjs" "$@"
