# dsh-launcher

> 把 **DeepSeek Harness** 变成 macOS 原生使用体验:官方 Runtime 零修改、零 fork,
> Safari Web App (PWA) 全屏 UI、按需启动的极薄生命周期管理器(**TypeScript 实现**)。

[![CI](https://github.com/3kaiu/dsh-launcher/actions/workflows/ci.yml/badge.svg)](https://github.com/3kaiu/dsh-launcher/actions/workflows/ci.yml)
[![Release](https://github.com/3kaiu/dsh-launcher/actions/workflows/release.yml/badge.svg)](https://github.com/3kaiu/dsh-launcher/actions/workflows/release.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

---

## 这是什么

DeepSeek 官方的 `dsh web` 是一个完整的 Agent Runtime(LLM / Shell / Terminal / MCP /
Workspace / Sessions / Plugins),Web UI 本身就是按 PWA 方向设计的:Safari「添加到程序坞」后
就是一个独立全屏 Web App。

本项目是 **外部生命周期管理器(TypeScript)**,只做一件事:

> **检测 → 安装上游最新运行时 → 启动 → 等待就绪 → 打开 → 停止 → 崩溃自愈**

官方代码一行不改。不用的时候进程为零,不占任何内存。

## 版本策略:不写死,始终跟随上游最新

- **node**:每次运行时查询 `nodejs.org/dist/index.json` 取最新 LTS(SHA-256 校验下载);
- **@deepseek-ai/dsh**:安装时用 `latest` tag,npm 解析上游最新发行版,实际版本记录在 `~/.local/share/dsh-runtime/versions.json`;
- **自动升级**:每次 `dshctl start` 都会在线复查上游,发现新版自动升级后再启动(离线时回退本地版本并提示);
- 包内自带的 node 是构建时(CI)取的最新 LTS,仅作首次引导;运行时升级后自动使用最新运行时 node。

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
│   dsh web — 官方 @deepseek-ai/dsh (latest)        │
│            │                                      │
│            ▼                                      │
│   Cordis Runtime: LLM / Shell / Terminal / MCP    │
│   / Workspace / Sessions / Plugins                │
│            │                                      │
│            ▼                                      │
│   DeepSeek API                                    │
│                                                   │
│   dshctl(TypeScript,便携包自带 node):            │
│     install/start/stop/restart/status/logs/       │
│     open/update/watch/doctor                      │
└───────────────────────────────────────────────────┘
```

## 快速开始(下载即用,零配置)

### 方式 A:下载 Release 包(推荐)

1. 从 [Releases](../../releases) 下载 `dshctl-macos-<arm64|x64>-<版本>.zip`(包内自带 node 二进制,无需安装任何东西);
2. 解压,然后:

```bash
./dshctl start     # 全部自动:查询上游最新 node/dsh → 安装 → 启动 → 打开浏览器
# Safari 打开 http://127.0.0.1:3080 完成模型 / API Key 配置
# Safari → 文件 → 添加到程序坞 → 之后从 Dock 全屏打开
```

(可选)安装到 PATH 与自启:

```bash
./install.sh       # 装到 ~/.local/share/dsh-launcher + ~/.local/bin/dshctl
dshctl watch       # 崩溃自愈(可选,前台守护)
```

### 方式 B:从源码构建

```bash
git clone https://github.com/3kaiu/dsh-launcher.git
cd dsh-launcher
npm i               # typescript(devDep)
npm test            # 单测(node --test,原生 TS)
npx tsc --noEmit    # 类型检查
node scripts/release.ts dev arm64   # 构建便携包 → dist/dshctl-macos-arm64-dev.zip
bash scripts/smoke-test.sh          # 集成冒烟(真实安装上游最新 node+dsh)
```

## dshctl 命令

| 命令 | 说明 |
| --- | --- |
| `dshctl start` | 全自动:复查上游最新版本 → 需要时升级 → 启动 `dsh web` → 就绪 → 自动打开(已运行则直接返回) |
| `dshctl stop` | 停止并等待端口释放(退出后无残留进程) |
| `dshctl restart` | 重启 |
| `dshctl status` | 状态(0=运行中,1=未运行)+ 当前 node/dsh 版本 |
| `dshctl logs` | 最近日志 |
| `dshctl open` | 确保运行中,然后打开 Web App / 浏览器 |
| `dshctl update` | 手动检查并升级到上游最新(平时 start 已自动检查) |
| `dshctl watch` | 前台守护:崩溃自动拉起 |
| `dshctl doctor` | 健康检查(运行时/进程/版本) |
| `dshctl install` | 确保运行时为上游最新(幂等) |

环境变量(可选):`DSH_RT_HOME`(运行时目录,默认 `~/.local/share/dsh-runtime`)、`DSH_RT_STATE`、`DSH_RT_PORT`(默认 3080)、`DSH_RT_HOST`、`DSH_HOME`、`DSHCTL_NO_OPEN=1`(禁止自动打开)。

## 结构

```text
src/versions.ts      # 上游版本动态解析(纯函数,单测覆盖)
src/dshctl.ts        # CLI 主程序(TypeScript)
scripts/release.ts   # 构建脚本:取最新 LTS node → bundle → 便携包 zip + SHA256SUMS
scripts/wrapper.sh   # 便携包启动包装(优先最新运行时 node)
scripts/install.sh   # 安装到 ~/.local/share/dsh-launcher + ~/.local/bin
scripts/smoke-test.sh# 集成冒烟(真实安装上游最新运行时)
test/versions.test.mjs # 单测(node --test)
launchd/             # (可选)登录自启模板
```

> 注:菜单栏 App(app/)源码保留但构建暂缓;便携包 dshctl 是当前推荐的唯一入口。

详见 [docs/pwa-setup.md](docs/pwa-setup.md)。
