#!/usr/bin/env bash
set -euo pipefail
# 安装 dsh-launcher:把 dshctl 安装到 ~/.local/bin
# 用法: bash scripts/install.sh(仓库内)或 ./install.sh(release 包内)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN_DIR="${DSH_LAUNCHER_BIN_DIR:-$HOME/.local/bin}"
mkdir -p "$BIN_DIR"
install -m 0755 "$ROOT/dshctl" "$BIN_DIR/dshctl"
echo "✓ dshctl 已安装到 $BIN_DIR/dshctl"
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) printf '提示: %s 不在 PATH,请执行:\n' "$BIN_DIR"
     printf '  echo '\''export PATH="%s:$PATH"'\'' >> ~/.zshrc\n' "$BIN_DIR"
     ;;
esac
echo ""
echo "下一步:"
echo "  1) dshctl start              # 首次自动安装 Node 24 LTS + 官方 dsh 并启动"
echo "  2) Safari 打开 http://127.0.0.1:3080 完成首次配置(API Key)"
echo "  3) Safari → 文件 → 添加到程序坞,以后从 Dock 全屏打开 (docs/pwa-setup.md)"
echo "  4) dshctl open               # 一键:确保运行中 + 打开 PWA"
echo "  5) (可选) dshctl agent-install   # 登录自启 + 崩溃自愈"
