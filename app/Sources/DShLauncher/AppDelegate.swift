import AppKit
import Foundation

// DeepSeek Harness Launcher — 菜单栏控制器
// 职责:管理官方 dsh 运行时的生命周期(启动/停止/重启/状态/日志目录)。
// UI 由 Safari Web App (PWA) 提供,本 App 不包含任何官方代码,只调用 dshctl。

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    private var statusItem: NSStatusItem!
    private var stateItem: NSMenuItem!
    private var startItem: NSMenuItem!
    private var stopItem: NSMenuItem!
    private var restartItem: NSMenuItem!
    private var running = false
    private var busy = false

    private let port = ProcessInfo.processInfo.environment["DSH_RT_PORT"] ?? "3080"

    // MARK: - App 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "hammer.fill", accessibilityDescription: "DeepSeek Harness")
            image?.isTemplate = true
            button.image = image
        }
        buildMenu()
        refresh()
        Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    // MARK: - 菜单

    private func buildMenu() {
        let menu = NSMenu()

        stateItem = NSMenuItem(title: "状态…", action: nil, keyEquivalent: "")
        stateItem.isEnabled = false
        menu.addItem(stateItem)
        menu.addItem(NSMenuItem.separator())

        let openItem = NSMenuItem(title: "打开 DeepSeek Harness", action: #selector(openPWA), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)

        startItem = NSMenuItem(title: "启动运行时", action: #selector(startRuntime), keyEquivalent: "")
        startItem.target = self
        menu.addItem(startItem)

        stopItem = NSMenuItem(title: "停止运行时", action: #selector(stopRuntime), keyEquivalent: "")
        stopItem.target = self
        menu.addItem(stopItem)

        restartItem = NSMenuItem(title: "重启运行时", action: #selector(restartRuntime), keyEquivalent: "")
        restartItem.target = self
        menu.addItem(restartItem)
        menu.addItem(NSMenuItem.separator())

        let detailItem = NSMenuItem(title: "运行状态详情…", action: #selector(showDetail), keyEquivalent: "")
        detailItem.target = self
        menu.addItem(detailItem)

        let logsItem = NSMenuItem(title: "打开日志目录", action: #selector(openLogs), keyEquivalent: "")
        logsItem.target = self
        menu.addItem(logsItem)

        let rtItem = NSMenuItem(title: "打开运行时目录", action: #selector(openRuntimeDir), keyEquivalent: "")
        rtItem.target = self
        menu.addItem(rtItem)
        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func updateMenu() {
        if busy {
            stateItem.title = "⋯ 操作中…"
        } else {
            let dot = running ? "●" : "○"
            let state = running ? "运行中" : "已停止"
            stateItem.title = dot + " " + state + " · 127.0.0.1:" + port
        }
        startItem.title = busy ? "启动中…" : "启动运行时"
        startItem.isEnabled = !running && !busy
        stopItem.isEnabled = running && !busy
        restartItem.isEnabled = !busy
    }

    // MARK: - dshctl 调用

    private func ctlPath() -> String? {
        if let bundled = Bundle.main.path(forResource: "dshctl", ofType: nil),
           FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }
        let homePath = NSHomeDirectory() + "/.local/bin/dshctl"
        return FileManager.default.isExecutableFile(atPath: homePath) ? homePath : nil
    }

    @discardableResult
    private func runCtl(_ args: [String]) -> (code: Int32, out: String) {
        guard let ctl = ctlPath() else { return (127, "找不到 dshctl(请先运行 scripts/install.sh)") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [ctl] + args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(data: data, encoding: .utf8) ?? ""
            return (process.terminationStatus, text)
        } catch {
            return (126, "启动 dshctl 失败: \(error)")
        }
    }

    private func runAsync(_ args: [String]) {
        guard !busy else { return }
        busy = true
        updateMenu()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            self.runCtl(args)
            DispatchQueue.main.async {
                self.busy = false
                self.refresh()
            }
        }
    }

    // MARK: - 动作

    @objc private func openPWA() { runAsync(["open"]) }
    @objc private func startRuntime() { runAsync(["start"]) }
    @objc private func stopRuntime() { runAsync(["stop"]) }
    @objc private func restartRuntime() { runAsync(["restart"]) }

    @objc private func showDetail() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let (_, status) = self.runCtl(["status"])
            let (_, doctor) = self.runCtl(["doctor"])
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "DeepSeek Harness Launcher"
                alert.informativeText = status + "\n" + doctor
                alert.addButton(withTitle: "好")
                alert.runModal()
            }
        }
    }

    @objc private func openLogs() {
        let env = ProcessInfo.processInfo.environment
        let state = env["DSH_RT_STATE"] ?? NSHomeDirectory() + "/.local/state/dsh-runtime"
        let dir = state + "/logs"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: dir, isDirectory: true))
    }

    @objc private func openRuntimeDir() {
        let env = ProcessInfo.processInfo.environment
        let home = env["DSH_RT_HOME"] ?? NSHomeDirectory() + "/.local/share/dsh-runtime"
        try? FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: home, isDirectory: true))
    }

    // MARK: - 状态刷新

    private func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let (_, out) = self.runCtl(["status"])
            let isRunning = out.contains("状态: 运行中")
            DispatchQueue.main.async {
                self.running = isRunning
                self.updateMenu()
            }
        }
    }
}