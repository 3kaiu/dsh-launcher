# dsh-pwa

macOS 上一键安装 [DeepSeek Harness](https://www.npmjs.com/package/@deepseek-ai/dsh)(官方 npm 包 `@deepseek-ai/dsh`)并把它变成常驻的桌面 PWA:

- 登录即启动一个 **~1.3MB 守护进程**(LaunchAgent),无需打开终端
- 在 Safari 中「添加到程序坞」即得全屏 Web App 图标,随时唤起
- dsh 空闲(默认 60s 无连接)自动停止,不占 CPU / 内存
- 一键跟随上游最新版(`@deepseek-ai/dsh`、Node LTS),幂等升级

## 安装

```bash
curl -fsSL https://raw.githubusercontent.com/3kaiu/dsh-pwa/main/scripts/install.sh | bash
```

安装器会自动:

1. 复用系统已有 Node(≥22,兼容 fnm / volta / nvm 的 shim 路径),否则安装 nodejs.org 最新 LTS(校验 SHA-256)
2. 安装官方 `@deepseek-ai/dsh@latest`(带实时下载百分比)
3. 编译/复用守护进程并注册 LaunchAgent
4. 自动打开 `http://127.0.0.1:3080/`

> 升级 = 重跑同一条命令,已是最新时秒级跳过。

## 如何工作

```
Safari 程序坞 PWA ──http://127.0.0.1:3080──> daemon(常驻,~1.3MB RSS)
                                              │ 未运行:返回引导页,页面自动 POST /wake
                                              │ 运行中:双向透传 dsh 的 Web UI
                                              └─> 直启 node + dsh web(内部端口随机分配,
                                                  写入 RT_STATE/dsh.json)
```

- 守护只监听 `127.0.0.1`,不透传控制端点(`/health` `/wake` `/stop`)之外的任何权限
- 连接归零 `DSH_RT_IDLE_STOP_SECS` 秒后自动 `SIGTERM` 停止 dsh

## 环境变量

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `DSH_RT_PORT` | `3080` | 守护(PWA)端口 |
| `DSH_RT_IDLE_STOP_SECS` | `60` | 空闲多少秒后停止 dsh |
| `DSH_RT_HOME` | `~/.local/share/dsh-runtime` | 运行时目录(node / app / daemon) |
| `DSH_RT_STATE` | `~/.local/state/dsh-runtime` | 状态与日志 |
| `DSH_HOME` | `~/.dsh` | dsh 自己的数据目录 |
| `DSH_INSTALL_NO_AGENT` | - | 安装时不注册 LaunchAgent(测试用) |
| `DSH_RT_NO_SYSTEM_NODE` | - | 不探测系统 node,强制安装自带 Node LTS |

## 开发

```bash
bash scripts/smoke-test.sh   # 隔离目录真实安装 → 幂等重跑 → 唤醒/透传 → 空闲自停
```

CI(macOS)每次 push 都会跑守护编译检查(`clang -Wall -Wextra`)+ 完整冒烟。