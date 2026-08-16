# dsh-launcher

> 把 **DeepSeek Harness** 变成 macOS 原生使用体验:官方 Runtime 零修改、零 fork,
> Safari Web App (PWA) 全屏 UI、按需启动的极薄生命周期管理器。

[![CI](https://github.com/3kaiu/dsh-launcher/actions/workflows/ci.yml/badge.svg)](https://github.com/3kaiu/dsh-launcher/actions/workflows/ci.yml)
[![Release](https://github.com/3kaiu/dsh-launcher/actions/workflows/release.yml/badge.svg)](https://github.com/3kaiu/dsh-launcher/actions/workflows/release.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

---

## 这是什么

DeepSeek 官方的 `dsh web` 是一个完整的 Agent Runtime(LLM / Shell / Terminal / MCP /
Workspace / Sessions / Plugins),Web UI 本身就是按 PWA 方向设计的:
官方 `manifest.webmanifest` 自带 `"display": "fullscreen"`,Safari「添加到程序坞」后
就是一个独立全屏 Web App。

本项目的定位是 **外部生命周期管理器**,只做一件事:

> **检测 → 启动 → 等待就绪 → 打开 → 停止 → 崩溃自愈**

官方代码一行不改。不用的时候进程为零,不占任何内存。

## 架构

```text
                     macOS
┌───────────────────────────────────────────────────┐
│                                                   │
│   Safari Web App "DeepSeek Harness"               │
│   (官方 manifest → display: fullscreen)           │
│            │                                      │
│            │ http://127.0.0.1:3080                │
│            ▼                                      │
│   dsh web — 官方 @deepseek-ai/dsh (固定版本)      │
│            │                                      │
│            ▼                                      │
│   Cordis Runtime: LLM / Shell / Terminal / MCP    │
│   / Workspace / Sessions / Plugins                │
│            │                                      │
│            ▼                                      │
│   DeepSeek API                                    │
│                                                   │
│   dshctl(本仓库):install/start/stop/status/...   │
│   (可选) LaunchAgent:登录自启 + 崩溃自愈          │
│   (可选) 菜单栏 App:DeepSeek Harness Launcher     │
└───────────────────────────────────────────────────┘
```

## 为什么不是 Pake / Electron / Tauri

| 方案 | 评价 |
| --- | --- |
| ✅ **官方 dsh + Safari PWA + dshctl(本项目)** | 零修改零 fork;不用时不占进程;官方更新只需换版本号 |
| Pake / Tauri 套壳 | 官方 UI 已经是 Web App,再套 WebView = 套娃 |
| Electron | 重量级,与「极薄」目标相悖 |
| Fork 官方改 Native | 官方是 developer preview(明确有破坏性变更),fork = 自找麻烦 |

## 快速开始

### 方式 A:下载 Release 包(推荐)

1. 从 [Releases](../../releases) 下载 `dsh-launcher-macos-<版本>.zip`
2. 解压后运行 `./install.sh`(把 `dshctl` 装到 `~/.local/bin`)
3. 启动并完成首次配置:

```bash
dshctl start        # 首次自动下载 Node 24 LTS(校验 SHA-256)+ 安装官方 dsh
# Safari 打开 http://127.0.0.1:3080 ,完成模型 / API Key 配置
# Safari → 文件 → 添加到程序坞 → 之后从 Dock 全屏打开
```

### 方式 B:从源码跑

```bash
git clone https://github.com/3kaiu/dsh-launcher.git
cd dsh-launcher
bash scripts/install.sh
dshctl start
```

### 之后

```bash
dshctl open     # 一键:确保运行时在线 + 打开 PWA(优先打开 Dock 里的 Web App)
```

详见 [docs/pwa-setup.md](docs/pwa-setup.md)。

## dshctl 命令

| 命令 | 说明 |
| --- | --- |
| `dshctl install` | 安装固定版本 Node + 官方 dsh(幂等) |
| `dshctl start` | 按需启动 `dsh web`,等待就绪(已运行则直接返回) |
| `dshctl stop` | 停止并等待端口释放(退出后无残留进程) |
| `dshctl restart` | 重启 |
| `dshctl status` | 状态(0=运行中,1=未运行) |
| `dshctl open` | 确保运行中,然后打开 Web App / 浏览器 |
| `dshctl logs [-f] [N]` | 查看日志 |
| `dshctl update [version]` | 升级 dsh(默认 npm latest) |
| `dshctl doctor` | 环境体检 |
| `dshctl watch` | 守护循环:掉线自动重启(供 launchd 使用) |
| `dshctl agent-install` / `agent-uninstall` | 安装/卸载 LaunchAgent |

### 常用环境变量

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `DSH_RT_PORT` | 3080 | 监听端口 |
| `DSH_RT_NODE_VERSION` | 24.19.0 | 固定 Node 版本(LTS) |
| `DSH_RT_DSH_VERSION` | 0.1.0-rc.6 | 固定 dsh 版本 |
| `DSH_RT_HOME` | ~/.local/share/dsh-runtime | 运行时目录 |
| `DSH_RT_STATE` | ~/.local/state/dsh-runtime | PID / 日志目录 |

## 固定版本与更新

- **Node 24.19.0**:官方 nodejs.org tarball,下载后校验 SHASUMS256.txt
- **@deepseek-ai/dsh 0.1.0-rc.6**:npm 固定版本,独立于系统 Node / nvm
- 升级 dsh:`dshctl update`(查 npm latest)或 `dshctl update 0.2.0-rc.1`
- 升级后重启生效:`dshctl restart`

## 可选:登录自启 + 崩溃自愈

```bash
dshctl agent-install    # 生成 ~/Library/LaunchAgents/com.dsh-launcher.runtime.plist
```

原理:launchd 以 `KeepAlive` 运行 `dshctl watch`(每 10s 健康检查,掉线自动拉起),
登录后自动启动、崩溃自动恢复。不需要时:`dshctl agent-uninstall`。
模板见 [launchd/com.dshlauncher.runtime.plist](launchd/com.dshlauncher.runtime.plist)。

## 菜单栏 App(可选)

`DeepSeek Harness Launcher.app`(Swift,零第三方依赖):

- 状态栏显示运行状态(●/○),每 5s 刷新
- 菜单:打开 PWA / 启动 / 停止 / 重启 / 状态详情 / 日志目录 / 运行时目录 / 退出
- 打包了内置 `dshctl`,不依赖任何官方源码

```bash
bash scripts/build-app.sh   # 本地构建,产物在 dist/
```

## 从 GitHub Actions 直接构建

本项目完全由 GitHub 构建,本地无需任何构建环境:

| 事件 | 自动执行 |
| --- | --- |
| push / PR | CI:shellcheck 静态检查 + **真实集成冒烟**(macOS runner 上安装 Node 24 + 官方 dsh,跑完 install → start → HTTP 200 → manifest → stop)+ 构建 .app |
| 打 tag `v0.1.0` | Release:构建发布包并创建 GitHub Release(附 `dsh-launcher-macos-v0.1.0.zip` + SHA256SUMS.txt) |
| 手动 | 两个工作流都支持 `workflow_dispatch` 手动触发 |

所以:**你只需要推代码、打 tag,构建全部在 GitHub 上完成**。

## 目录结构

```text
dsh-launcher/
├── dshctl                  # 核心:运行时生命周期管理器(单文件 bash,零依赖)
├── scripts/
│   ├── install.sh          # 安装 dshctl 到 ~/.local/bin
│   ├── smoke-test.sh       # 隔离环境冒烟测试(CI + 本地通用)
│   └── build-app.sh        # 构建菜单栏 App + 发布包
├── app/                    # Swift 菜单栏 App (SwiftPM,无第三方依赖)
├── tools/gen-icon.mjs      # 图标生成器(纯 Node 零依赖)
├── launchd/                # LaunchAgent 模板
├── docs/pwa-setup.md       # Safari 添加到程序坞步骤
└── .github/workflows/      # ci.yml + release.yml
```

## 开发

```bash
# 本地完整验证(隔离目录,不影响你的真实环境)
bash scripts/smoke-test.sh

# 本地构建 .app
bash scripts/build-app.sh
```

## 卸载

```bash
dshctl agent-uninstall      # 若有 LaunchAgent
dshctl stop
rm -rf ~/.local/share/dsh-runtime ~/.local/state/dsh-runtime
rm -f ~/.local/bin/dshctl
# 程序坞右键 DeepSeek Harness → 选项 → 从程序坞移除,删除 ~/Applications/DeepSeek Harness.app
```

## FAQ

- **3080 被占用?** 那是另一个 dsh 实例在跑——`dshctl start` 会直接识别为已运行并复用;
  想换端口:`DSH_RT_PORT=8080 dshctl start`(Web App 需重新添加程序坞)。
- **安全吗?** `dsh web` 默认只绑定 127.0.0.1,仅本机可访问。
- **官方更新了怎么办?** `dshctl update`,或等本项目默认版本更新后重新 install。
- **以后 DeepSeek 出官方 macOS App?** 直接换掉外面的 launcher 即可,使用习惯不变。
- **需要 Node / npm 吗?** 不需要,自带固定版本,与系统环境完全隔离。

## 参考

- [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)(官方仓库,developer preview)
- 官方 Web App 自带 [manifest.webmanifest](https://github.com/deepseek-ai/deepseek-harness/blob/master/apps/web/public/manifest.webmanifest)
- 官方 CLI 文档([apps/cli](https://github.com/deepseek-ai/deepseek-harness/tree/master/apps/cli)):`dsh web` = `--profile web`,支持 `--host/--port`

## License

MIT © 2026 3kaiu
