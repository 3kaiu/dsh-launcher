# 把 DeepSeek Harness 添加到程序坞(Safari Web App / PWA)

官方 Web App 已经自带 `manifest.webmanifest`(`display: fullscreen`),所以不需要任何
额外工具,直接用 Safari 的原生「添加到程序坞」即可获得独立全屏窗口。

## 步骤

1. 启动运行时:
   ```bash
   dshctl start
   ```
   (dmg 版已内置运行时;命令行版首次会自动下载最新 LTS Node 并安装官方 `@deepseek-ai/dsh`)

2. 用 Safari 打开 http://127.0.0.1:3080 ,完成首次配置(模型 / API Key 等)。

3. 菜单栏 **文件 → 添加到程序坞**(macOS 26 / Safari 26)。
   - 如果你的 Safari 版本没有这个菜单项,请升级系统 / Safari。
   - 应用名称会取官方 manifest 的 name:**DeepSeek Harness**。

4. 完成。程序坞会出现 **DeepSeek Harness** 图标,点击即以全屏独立窗口打开
   (对应 manifest 的 `display: fullscreen`),关闭窗口后运行时仍然驻留。

## 之后的使用

| 场景 | 操作 |
| --- | --- |
| 打开 PWA(自动确保运行时已启动) | `dshctl open` |
| 仅启动运行时 | `dshctl start` |
| 停止运行时(释放内存,退出后无残留进程) | `dshctl stop` |

`dshctl open` 会优先打开 ~/Applications 里的 **DeepSeek Harness** Web App;
如果还没添加程序坞,则回退为 Safari 打开页面。

## 常见问题

- **添加到程序坞后打不开**:确认运行时在线(`dshctl status`),Web App 只是浏览器窗口。
- **想改名**:在程序坞右键 → 选项 → 在 Finder 中显示,重命名 .app 后重新拖入程序坞。
- **移除**:程序坞右键 → 选项 → 从程序坞移除,再删除 ~/Applications/DeepSeek Harness.app。
