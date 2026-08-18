# 把 DeepSeek Harness 添加到程序坞(PWA,自动拉起 + 关闭即停)

程序坞里只留一个 **DeepSeek Harness** PWA 图标。点击它 → 引导页自动检测 dsh → 未运行则
自动拉起 → 就绪后进入完整 UI;**关闭 PWA 后连接归零约 60 秒,dsh 自动停止**(释放内存,
无残留进程)。dsh 不用开机常驻,守护本身极轻(C 二进制 ~1.3MB RSS)。

背后是一个常驻守护(`com.dshlauncher.daemon`,只应答引导页 / 透传 / 拉起 / 停止,不运行
Agent / 不加载插件;`dshctl daemon off` 可随时移除)。

## 单端口自动匹配(无硬编码双端口)

- **PWA 端口 = `DSH_RT_PORT`(默认 3080),由守护独占。** 无论 dsh 在不在跑,这个地址永远能打开:
  dsh 未运行 → 返回引导页(自动拉起);dsh 运行中 → 双向透传直达 UI。
- dsh 的内部端口是**启动时自动挑选的空闲端口**,写入 `RT_STATE/dsh.json`。守护重启 / PWA 重连
  都会自动发现,无需配置、不会冲突。

## 安装(一次性)

1. 双击一次 **DeepSeek Harness.app**(或命令行版先 `dshctl install` 再 `dshctl daemon on`)。
   这一步注册常驻守护并自动打开 PWA 入口 http://127.0.0.1:3080/ 。

2. 引导页会自动拉起 dsh(首次可能需数分钟安装运行时),就绪后进入完整 UI。
   在 Safari 里完成首次配置(模型 / API Key 等)。

3. 菜单栏 **文件 → 添加到程序坞**(macOS 26 / Safari 26)。应用名称取入口页 manifest:
   **DeepSeek Harness**。

4. 完成。程序坞出现 **DeepSeek Harness** 图标。

## 日常使用

| 场景 | 操作 |
| --- | --- |
| 打开(自动确保 dsh 运行) | 点击 Dock 里的 PWA,引导页自动拉起后进入 UI |
| 关闭(自动停止 dsh) | 直接关闭 PWA 窗口;约 60 秒后 dsh 自动停止(可 `dshctl daemon status` 确认) |
| 仅启动运行时(不打开页面) | `dshctl start`(守护在线时同样走自动拉起) |
| 立即停止运行时 | `dshctl stop` |
| 守护管理 | `dshctl daemon on / off / status` |
| 查看更新提示 | 引导页会显示上游新版提示,`dshctl update` 升级 |

## 工作原理

```text
Dock → PWA(127.0.0.1:3080,守护独占,永远能打开)
     → dsh 在跑? → 透传直达 UI
     → 不在跑 → 引导页 POST /wake → 守护挑空闲内部端口拉起 dsh(写入 dsh.json)→ 轮询就绪 → 进入 UI
PWA 关闭 → 连接归零 60 秒(DSH_RT_IDLE_STOP_SECS)→ 守护自动停止 dsh
```

## 常见问题

- **点击 PWA 显示"无法连接"**:这是 Safari 恢复了上次会话(停留在旧错误页),
  点地址栏重新加载或关窗重开即可回到入口页自动拉起。
- **想改空闲停止时长**:`launchctl setenv DSH_RT_IDLE_STOP_SECS 120` 后重启守护
  (`launchctl kickstart -k gui/$(id -u)/com.dshlauncher.daemon`);0 = 关闭空闲自停。
- **想改名**:程序坞右键 → 选项 → 在 Finder 中显示,重命名 .app 后重新拖入程序坞。
- **移除**:程序坞右键 → 选项 → 从程序坞移除,再删除 ~/Applications/DeepSeek Harness.app。
- **完全不用守护**:`dshctl daemon off`,之后只用 `dshctl start/open`(无常驻进程,dsh 常驻直到手动 stop)。