# DeepSeek Harness —— 程序坞 PWA 使用说明

程序坞里只留一个 **DeepSeek Harness** PWA 图标。点击它 → 自动拉起 dsh(官方最新版)→ 进入
完整 UI;关闭 PWA 后约 60 秒,dsh 自动停止(释放内存,无残留进程)。

## 安装(一次性)

1. 从 GitHub Releases 下载 **dsh-launcher.zip**(CI 自动构建):`https://github.com/3kaiu/dsh-launcher/releases`
2. 解压后运行:
   ```bash
   bash install.sh
   ```
   install.sh 自动完成:
   - 安装运行时到 `~/.local/share/dsh-runtime/`:**nodejs.org 最新 LTS**(SHA-256 校验)+ **官方 dsh@latest**(npm,跟随上游最新)
   - 编译/安装常驻守护(C 二进制 ~1.3MB RSS)
   - 注册 LaunchAgent(`com.dshlauncher.daemon`,登录即常驻,`launchctl bootout gui/$(id -u)/com.dshlauncher.daemon` 可移除)
3. 打开 http://127.0.0.1:3080/ → dsh 自动拉起,首次配置模型 / API Key。
4. Safari 菜单栏 **文件 → 添加到程序坞**,应用名 **DeepSeek Harness**。完成。

## 日常使用

| 场景 | 操作 |
| --- | --- |
| 打开(自动启动 dsh) | 点击 Dock 里的 PWA;若 dsh 未运行,引导页自动拉起后进入 UI |
| 关闭(自动停止 dsh) | 关掉 PWA 窗口;约 60 秒后 dsh 自动停止(`DSH_RT_IDLE_STOP_SECS` 可调) |
| 升级 dsh / node | 重跑 `bash install.sh`(版本不同才重装,自动跟随官方最新) |

## 工作原理

```text
Dock → PWA(127.0.0.1:3080,守护独占,永远能打开)
     → dsh 在跑? → 双向透传直达 UI
     → 不在跑 → 引导页 POST /wake → 守护挑空闲内部端口直启 dsh(写 RT_STATE/dsh.json)→ 轮询就绪 → 进入 UI
PWA 关闭 → 连接归零 60 秒 → 守护自动停止 dsh
```

dsh 的内部端口启动时自动挑选,全链路单一端口 3080,无硬编码双端口。

## 环境变量(可选)

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `DSH_RT_PORT` | 3080 | PWA 端口(改端口需同步修改 LaunchAgent 里的 plist) |
| `DSH_RT_HOME` / `DSH_RT_STATE` | `~/.local/share|state/dsh-runtime` | 运行时/状态目录 |
| `DSH_HOME` | `~/.dsh` | dsh 数据目录(模型配置等) |
| `DSH_RT_IDLE_STOP_SECS` | 60 | PWA 关闭后多久自动停止 dsh;0 = 关闭空闲自停 |

## 常见问题

- **点击 PWA 显示"无法连接"**:Safari 恢复了上次会话,点地址栏重新加载或关窗重开。
- **想改名**:程序坞右键 → 选项 → 在 Finder 中显示,重命名 .app 后重新拖入程序坞。
- **完全移除**:`launchctl bootout gui/$(id -u)/com.dshlauncher.daemon` + 删除
  `~/Library/LaunchAgents/com.dshlauncher.daemon.plist` + `rm -rf ~/.local/share/dsh-runtime ~/.local/state/dsh-runtime`。