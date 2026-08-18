#!/usr/bin/env bash
set -euo pipefail
# 安装 dshctl 便携包:包 → ~/.local/share/dsh-launcher/,dshctl → ~/.local/bin
# 用法: ./install.sh(包根内)或 bash scripts/install.sh(仓库内,构建后)
SRC="$(cd "$(dirname "$0")" && pwd)"
# 仓库内运行时定位 dist/stage
if [ -d "$SRC/../dist" ]; then
  STAGE="$(ls -d "$SRC"/../dist/stage 2>/dev/null | head -1 || true)"
  [ -n "$STAGE" ] && [ -x "$STAGE/dshctl" ] && SRC="$STAGE"
fi
[ -x "$SRC/dshctl" ] || { echo "找不到便携包 dshctl(先运行 node scripts/release.ts)" >&2; exit 1; }
DEST="${DSH_LAUNCHER_DIR:-$HOME/.local/share/dsh-launcher}"
BIN_DIR="${DSH_LAUNCHER_BIN_DIR:-$HOME/.local/bin}"
mkdir -p "$DEST" "$BIN_DIR"
rm -rf "$DEST"
mkdir -p "$DEST"
cp "$SRC/dshctl.ts" "$SRC/versions.ts" "$SRC/wrapper.sh" "$SRC/com.dshlauncher.daemon.plist" "$DEST/"
[ -f "$SRC/daemon" ] && cp "$SRC/daemon" "$DEST/"  # macOS 守护(可选)
cp "$SRC/dshctl" "$DEST/dshctl"
chmod +x "$DEST/dshctl"
ln -sf "$DEST/dshctl" "$BIN_DIR/dshctl"
echo "✓ dshctl 已安装: $BIN_DIR/dshctl (运行时: $DEST;首次 start 自动下载 node 最新 LTS + dsh latest)"
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) printf '提示: %s 不在 PATH,请执行:
  echo '\''export PATH="%s:$PATH"'\'' >> ~/.zshrc
' "$BIN_DIR" "$BIN_DIR" ;;
esac
echo ""
echo "下一步:"
echo "  1) dshctl start     # 自动:查询上游最新 node/dsh → 安装 → 启动 → 打开(零操作)"
echo "  2) dshctl daemon on # (可选)Dock 只留 PWA:注册常驻守护,引导页自动拉起 dsh"
echo "  3) Safari → 打开引导页 → 文件 → 添加到程序坞,以后从 Dock 全屏打开 (docs/pwa-setup.md)"
echo "  4) dshctl open      # 一键:确保运行中 + 打开 PWA"
echo "  5) dshctl update    # 手动检查上游新版(平时 start 已自动检查)"
echo "  6) dshctl doctor    # 健康检查"
