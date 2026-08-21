# dsh-pwa

macOS 上一键安装 [DeepSeek Harness](https://www.npmjs.com/package/@deepseek-ai/dsh)(官方 npm 包 `@deepseek-ai/dsh`)并把它变成常驻的桌面 PWA:登录即启动一个 ~1.3MB 守护进程(LaunchAgent),Safari「添加到程序坞」即得全屏 Web App;dsh 空闲自动停止,不占资源。

## 安装

```bash
curl -fsSL https://raw.githubusercontent.com/3kaiu/dsh-pwa/main/scripts/install.sh | bash
```

升级 = 重跑同一条命令(已最新则秒级跳过)。

## 卸载

```bash
launchctl bootout "gui/$(id -u)/com.dshpwa.daemon"
rm -f ~/Library/LaunchAgents/com.dshpwa.daemon.plist
rm -rf ~/.local/share/dsh-runtime ~/.local/state/dsh-runtime
```

## 开发

```bash
bash scripts/smoke-test.sh   # 隔离目录真实安装 → 幂等重跑 → 自动唤醒/就绪门控/透传 → 空闲自停
```
