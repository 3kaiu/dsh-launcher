#!/usr/bin/env node
// dshctl.ts —— DeepSeek Harness 运行时管理器(TypeScript,node >= 24 原生运行,零依赖)
// 生命周期: install / start / stop / restart / status / logs / open / update / watch / doctor
// 设计原则: 官方 dsh 零修改零 fork;node 与 dsh 版本不写死——每次运行跟随上游最新
//           (node = nodejs.org 最新 LTS,dsh = npm latest);按需启动,不用时零进程
import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { createWriteStream, existsSync, mkdirSync, openSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { Readable } from "node:stream";
import { pipeline } from "node:stream/promises";
import { arch, nodeLatestLts, dshLatest, nodeTarballUrl, nodeShasumsUrl } from "./versions.ts";
import type { ReadableStream as WebReadableStream } from "node:stream/web";
const env = (k: string): string | undefined => process.env[k]?.length ? process.env[k] : undefined;
const RT_HOME = env("DSH_RT_HOME") ?? join(homedir(), ".local", "share", "dsh-runtime");
const RT_STATE = env("DSH_RT_STATE") ?? join(homedir(), ".local", "state", "dsh-runtime");
const DSH_HOME = env("DSH_HOME") ?? join(homedir(), ".dsh");
const HOST = env("DSH_RT_HOST") ?? "127.0.0.1";
const PORT = Number(env("DSH_RT_PORT") ?? 3080);
const NODE_DIR = join(RT_HOME, "node");
const APP_DIR = join(RT_HOME, "app");
const NODE_BIN = join(NODE_DIR, "bin", "node");
const NPM_BIN = join(NODE_DIR, "bin", "npm");
const DSH_PKG = join(APP_DIR, "node_modules", "@deepseek-ai", "dsh", "package.json");

/** dsh 可执行入口:从官方 package.json 的 bin 字段动态解析,上游改名也不挂 */
function dshBin(): string {
  try {
    const pkg = JSON.parse(readFileSync(DSH_PKG, "utf8")) as { bin?: string | Record<string, string> };
    const bin = typeof pkg.bin === "string" ? pkg.bin : (pkg.bin?.dsh ?? "lib/bin.js");
    return join(dirname(DSH_PKG), bin);
  } catch { return join(APP_DIR, "node_modules", "@deepseek-ai", "dsh", "lib", "bin.js"); }
}
const VERSIONS_FILE = join(RT_HOME, "versions.json");
const PID_FILE = join(RT_STATE, "dsh.pid");
const LOG_DIR = join(RT_STATE, "logs");
const URL = "http://" + HOST + ":" + PORT;

interface Versions { node?: string; dsh?: string; installedAt?: string; checkedAt?: string; }

function readVersions(): Versions { try { return JSON.parse(readFileSync(VERSIONS_FILE, "utf8")) as Versions; } catch { return {}; } }
function writeVersions(v: Versions) { mkdirSync(RT_HOME, { recursive: true }); writeFileSync(VERSIONS_FILE, JSON.stringify({ ...v, installedAt: new Date().toISOString() }, null, 2) + "\n"); }

async function healthy(): Promise<boolean> {
  try { const res = await fetch(URL, { signal: AbortSignal.timeout(2000) }); return res.ok; } catch { return false; }
}
function pidAlive(pid: number): boolean { if (!pid) return false; try { process.kill(pid, 0); return true; } catch { return false; } }
function readPid(): number { try { return Number(readFileSync(PID_FILE, "utf8")) || 0; } catch { return 0; } }
/** 当前最新一份运行日志(用于启动中等待时追踪存活) */
function newestLog(): string | undefined {
  try { const list = readdirSync(LOG_DIR).sort(); return list.length ? join(LOG_DIR, list[list.length - 1]) : undefined; } catch { return undefined; }
}

async function waitReady(seconds: number, log?: string): Promise<boolean> {
  const deadline = Date.now() + seconds * 1000;
  while (Date.now() < deadline) {
    if (await healthy()) return true;
    if (log && !pidAlive(readPid())) break;
    await new Promise((r) => setTimeout(r, 1000));
  }
  return false;
}

// ---------- 运行时安装(动态版本:上游最新) ----------
async function installNode(ver: string): Promise<boolean> {
  const a = arch();
  const tar = join(RT_HOME, "node-" + ver + "-" + a + ".tar.gz");
  mkdirSync(RT_HOME, { recursive: true });
  console.log("下载 Node v" + ver + " (" + a + ") ...");
  try {
    const res = await fetch(nodeTarballUrl(ver, a), { signal: AbortSignal.timeout(15 * 60 * 1000) });
    if (!res.ok) throw new Error("下载失败 " + res.status);
    // 流式落盘,50MB 不占内存
    await pipeline(Readable.fromWeb(res.body as unknown as WebReadableStream), createWriteStream(tar));
    const sumsRes = await fetch(nodeShasumsUrl(ver), { signal: AbortSignal.timeout(30000) });
    if (sumsRes.ok) {
      const sums = await sumsRes.text();
      const expect = sums.split("\n").find((l) => l.includes("node-v" + ver + "-darwin-" + a + ".tar.gz"))?.split(/\s+/)[0];
      if (expect) {
        const actual = createHash("sha256").update(readFileSync(tar)).digest("hex");
        if (actual !== expect) throw new Error("SHA-256 校验失败(预期 " + expect + ",实际 " + actual + ")");
        console.log("SHA-256 校验通过");
      }
    }
    rmSync(NODE_DIR, { recursive: true, force: true });
    mkdirSync(NODE_DIR, { recursive: true });
    const t = spawnSync("tar", ["-xzf", tar, "-C", NODE_DIR, "--strip-components=1"]);
    if (t.status !== 0) throw new Error("解压失败");
    rmSync(tar, { force: true });
    console.log("Node v" + ver + " 安装完成 (" + NODE_DIR + ")");
    return true;
  } catch (e) { console.error("Node 安装失败: " + (e as Error).message); rmSync(tar, { force: true }); return false; }
}

function installDsh(): boolean {
  console.log("安装 @deepseek-ai/dsh@latest ...");
  try {
    mkdirSync(APP_DIR, { recursive: true });
    writeFileSync(join(APP_DIR, "package.json"), JSON.stringify({ name: "dsh-runtime-app", private: true, dependencies: { "@deepseek-ai/dsh": "latest" } }, null, 2) + "\n");
    const r = spawnSync(NPM_BIN, ["install", "--no-audit", "--no-fund", "--loglevel=error"], { cwd: APP_DIR, env: { ...process.env, PATH: NODE_DIR + "/bin:" + process.env.PATH }, stdio: "inherit" });
    if (r.status !== 0) throw new Error("npm install 失败(" + r.status + ")");
    const pkg = JSON.parse(readFileSync(DSH_PKG, "utf8")) as { version: string };
    // 剪除运行时不加载的调试/文档/测试文件(与 dmg 版保持一致)
    const prune = (dir: string): void => {
      for (const e of readdirSync(dir, { withFileTypes: true })) {
        const p = join(dir, e.name);
        if (e.isDirectory()) {
          if (e.name === "test" || e.name === "tests" || e.name === "__tests__") { rmSync(p, { recursive: true, force: true }); continue; }
          prune(p);
        } else if (e.name.endsWith(".map") || e.name.endsWith(".md") || e.name === ".DS_Store") rmSync(p, { force: true });
      }
    };
    prune(join(APP_DIR, "node_modules"));
    // 剪除遥测依赖(启动环境 DSH_TELEMETRY_DISABLED=1,插件不会加载;21M 纯磁盘占用)
    for (const sub of ["@opentelemetry", "@deepseek-ai/dsh-session-telemetry-otel"]) {
      rmSync(join(APP_DIR, "node_modules", sub), { recursive: true, force: true });
    }
    writeVersions({ ...readVersions(), dsh: pkg.version });
    console.log("dsh " + pkg.version + " 安装完成 (" + APP_DIR + ")");
    return true;
  } catch (e) { console.error("dsh 安装失败: " + (e as Error).message); return false; }
}

/** 并发安装锁:mkdir 原子互斥,锁内记录 pid 用于失效清理(双击连点/CLI 并发装同一运行时) */
const LOCK = join(RT_HOME, ".bootstrap.lock");
async function acquireLock(): Promise<boolean> {
  mkdirSync(RT_HOME, { recursive: true });
  for (let i = 0; i < 300; i++) {
    try { mkdirSync(LOCK); writeFileSync(join(LOCK, "pid"), String(process.pid)); return true; } catch {}
    try {
      const pid = Number(readFileSync(join(LOCK, "pid"), "utf8")) || 0;
      // 仅当 pid 有效且进程已死才判定失效;空 pid(持锁方尚未写入)只等待
      if (pid > 0 && !pidAlive(pid)) { rmSync(LOCK, { recursive: true, force: true }); continue; }
    } catch {}
    await new Promise((r) => setTimeout(r, 1000));
  }
  return false;
}
function releaseLock() { try { rmSync(LOCK, { recursive: true, force: true }); } catch {} }

async function ensureRuntime(): Promise<boolean> {
  let v = readVersions();
  // 包内预装运行时(versions.json 可能缺版本)→ 记录实际版本,避免重复下载/安装
  if (!v.node && existsSync(NODE_BIN)) {
    const r = spawnSync(NODE_BIN, ["--version"], { encoding: "utf8" });
    if (r.status === 0) v = { ...v, node: (r.stdout ?? "").trim().replace(/^v/, "") };
  }
  if (!v.dsh && existsSync(DSH_PKG)) {
    try {
      const pkg = JSON.parse(readFileSync(DSH_PKG, "utf8")) as { version: string };
      v = { ...v, dsh: pkg.version };
    } catch {}
  }
  if (v.node || v.dsh) writeVersions(v);
  // 上游复查缓存:1 小时内跳过在线检查,双击/start 即时启动(离线也不卡 10 秒)
  const stale = !v.checkedAt || Date.now() - new Date(v.checkedAt).getTime() > 60 * 60 * 1000;
  const [nodeLts, dshLatestV] = stale ? await Promise.all([nodeLatestLts(), dshLatest()]) : [null, null];
  if (nodeLts || dshLatestV) writeVersions({ ...v, checkedAt: new Date().toISOString() });
  // 无需任何安装/升级 → 直接可用
  if (existsSync(NODE_BIN) && existsSync(dshBin()) && (!nodeLts || v.node === nodeLts) && (!dshLatestV || v.dsh === dshLatestV)) return true;
  // 加锁安装(等锁期间并发进程可能已装好,拿锁后重读再决策)
  if (!(await acquireLock())) { console.error("等待安装锁超时(300s),请稍后重试"); return false; }
  try {
    v = readVersions();
    if (nodeLts && v.node !== nodeLts) {
      console.log("检测到上游新版 Node: " + (v.node ?? "无") + " → " + nodeLts);
      if (!(await installNode(nodeLts))) { console.error("升级 Node 失败,继续用本地版本"); } else writeVersions({ ...v, node: nodeLts });
    } else if (!existsSync(NODE_BIN)) {
      const ver = nodeLts ?? "24.19.0";
      if (!(await installNode(ver))) return false;
      writeVersions({ ...v, node: ver });
    }
    if (dshLatestV && v.dsh !== dshLatestV) {
      console.log("检测到上游新版 dsh: " + (v.dsh ?? "无") + " → " + dshLatestV);
      if (!installDsh()) console.error("升级 dsh 失败,继续用本地版本");
    } else if (!existsSync(dshBin())) {
      if (!installDsh()) return false;
    }
  } finally { releaseLock(); }
  return true;
}

// ---------- 生命周期 ----------
async function cmdStart(autoOpen = true): Promise<number> {
  if (await healthy()) {
    console.log("DeepSeek Harness 已在运行: " + URL);
    // 重复双击/start:直接把 PWA/浏览器打开,而不是什么都不做
    if (autoOpen && process.env.DSHCTL_NO_OPEN !== "1") openHarness();
    return 0;
  }
  // 启动中(pid 存活但未就绪):不重复拉起,等待当前实例就绪(避免二次双击抢端口报错)
  if (pidAlive(readPid())) {
    console.log("正在启动中,等待就绪...");
    if (await waitReady(120, newestLog())) {
      console.log("已就绪: " + URL);
      if (autoOpen && process.env.DSHCTL_NO_OPEN !== "1") openHarness();
      return 0;
    }
    console.error("等待就绪超时,日志: " + LOG_DIR);
    return 1;
  }
  if (!existsSync(NODE_BIN) || !existsSync(dshBin())) console.log("首次使用:自动安装运行时(跟随上游最新)...");
  if (!(await ensureRuntime())) return 1;
  mkdirSync(LOG_DIR, { recursive: true });
  // 日志只保留最近 10 个,避免长期累积
  for (const f of readdirSync(LOG_DIR).sort().slice(0, -10)) rmSync(join(LOG_DIR, f), { force: true });
  const log = join(LOG_DIR, "dsh-" + new Date().toISOString().replace(/[:.]/g, "-").slice(0, 19) + ".log");
  console.log("启动 dsh web (host=" + HOST + " port=" + PORT + "),日志: " + log);
  const fd = openSync(log, "a");
  const child = spawn(NODE_BIN, [dshBin(), "web", "--host", HOST, "--port", String(PORT)], {
    detached: true, stdio: ["ignore", fd, fd], env: { ...process.env, DSH_HOME, DSH_TELEMETRY_DISABLED: "1", PATH: NODE_DIR + "/bin:" + process.env.PATH },
  });
  child.unref();
  writeFileSync(PID_FILE, String(child.pid));
  if (await waitReady(120, log)) {
    console.log("已就绪: " + URL);
    if (autoOpen && process.env.DSHCTL_NO_OPEN !== "1") {
      openHarness();
    } else { console.log("提示: Safari 打开 " + URL + " → 文件 → 添加到程序坞(全屏 Web App)"); }
    return 0;
  }
  rmSync(PID_FILE, { force: true });
  console.error("启动超时,日志: " + log);
  return 1;
}

async function cmdStop(): Promise<number> {
  const pid = readPid();
  if (!pidAlive(pid)) { console.log("未在运行"); rmSync(PID_FILE, { force: true }); return 0; }
  try { process.kill(pid, "SIGTERM"); } catch {}
  for (let i = 0; i < 30; i++) { if (!(await healthy()) && !pidAlive(readPid())) break; await new Promise((r) => setTimeout(r, 1000)); }
  if (pidAlive(readPid())) { try { process.kill(readPid(), "SIGKILL"); } catch {} }
  rmSync(PID_FILE, { force: true });
  console.log("已停止");
  return 0;
}

async function cmdStatus(): Promise<number> {
  const v = readVersions();
  const pid = readPid();
  const ok = await healthy();
  console.log((ok ? "运行中" : "未运行") + " — " + URL);
  console.log("  node: " + (v.node ?? "未安装") + (existsSync(NODE_BIN) ? "" : "(缺失)"));
  console.log("  dsh:  " + (v.dsh ?? "未安装") + (existsSync(dshBin()) ? "" : "(缺失)"));
  console.log("  pid:  " + (pidAlive(pid) ? pid : "-"));
  return ok ? 0 : 1;
}

// 已添加到程序坞的 Safari Web App(com.apple.Safari.WebApp.*)
function safariWebApps(): string[] {
  const apps: string[] = [];
  for (const dir of [join(homedir(), "Applications"), "/Applications"]) {
    let entries: string[] = [];
    try { entries = readdirSync(dir).filter((n) => n.endsWith(".app")); } catch { continue; }
    for (const n of entries) {
      const p = join(dir, n, "Contents", "Info.plist");
      try { if (readFileSync(p, "utf8").includes("com.apple.Safari.WebApp")) apps.push(join(dir, n)); } catch {}
    }
  }
  return apps;
}
function openHarness(): void {
  const apps = safariWebApps();
  const hit = apps.find((a) => /deepseek|harness|dsh/i.test(a)) ?? apps[0];
  if (hit) { try { spawnSync("open", [hit]); console.log("已打开 Dock Web App: " + hit); return; } catch {} }
  try { spawnSync("open", [URL]); console.log("已打开: " + URL); } catch { console.log("请手动打开: " + URL); }
}

async function cmdOpen(): Promise<number> {
  if (!(await healthy())) { console.log("未运行,先启动..."); if ((await cmdStart(false)) !== 0) return 1; }
  openHarness();
  return 0;
}

async function cmdLogs(): Promise<number> {
  const logs = readdirSync(LOG_DIR).sort().slice(-3);
  if (!logs.length) { console.log("暂无日志"); return 0; }
  spawnSync("tail", ["-n", "50", ...logs.map((f) => join(LOG_DIR, f))], { stdio: "inherit" });
  return 0;
}

async function cmdUpdate(): Promise<number> {
  const v = readVersions();
  const [nodeLts, dshLatestV] = await Promise.all([nodeLatestLts(), dshLatest()]);
  console.log("上游: node LTS " + (nodeLts ?? "查询失败") + " / dsh " + (dshLatestV ?? "查询失败"));
  console.log("本地: node " + (v.node ?? "-") + " / dsh " + (v.dsh ?? "-"));
  if (nodeLts && v.node !== nodeLts && (await installNode(nodeLts))) writeVersions({ ...v, node: nodeLts });
  if (dshLatestV && v.dsh !== dshLatestV) installDsh();
  return 0;
}

async function cmdWatch(): Promise<number> {
  while (true) {
    if (!(await healthy())) { console.log("[" + new Date().toISOString() + "] 拉起..."); await cmdStart(false); }
    await new Promise((r) => setTimeout(r, 5000));
  }
}

async function cmdDoctor(): Promise<number> {
  const v = readVersions();
  const ok = await healthy();
  console.log("=== dshctl doctor ===");
  console.log("  运行时目录: " + RT_HOME);
  console.log("  node: " + (v.node ?? "-") + " " + (existsSync(NODE_BIN) ? "✅" : "❌ 缺失"));
  console.log("  dsh:  " + (v.dsh ?? "-") + " " + (existsSync(dshBin()) ? "✅" : "❌ 缺失"));
  console.log("  进程: " + (ok ? "✅ " + URL : "未运行"));
  return existsSync(NODE_BIN) && existsSync(dshBin()) ? 0 : 1;
}

const cmd = process.argv[2] ?? "help";
const main = async () => {
  switch (cmd) {
    case "install": process.exit((await ensureRuntime()) ? 0 : 1); break;
    case "start": process.exit(await cmdStart()); break;
    case "stop": process.exit(await cmdStop()); break;
    case "restart": await cmdStop(); process.exit(await cmdStart()); break;
    case "status": process.exit(await cmdStatus()); break;
    case "open": process.exit(await cmdOpen()); break;
    case "logs": process.exit(await cmdLogs()); break;
    case "update": process.exit(await cmdUpdate()); break;
    case "watch": process.exit(await cmdWatch()); break;
    case "doctor": process.exit(await cmdDoctor()); break;
    default:
      console.log("dshctl — DeepSeek Harness 运行时管理器(动态版本:node 最新 LTS + dsh latest)");
      console.log("用法: dshctl install|start|stop|restart|status|logs|open|update|watch|doctor");
      console.log("环境: DSH_RT_HOME DSH_RT_STATE DSH_RT_PORT DSH_RT_HOST DSH_HOME DSHCTL_NO_OPEN");
      console.log("首次 start 自动完成: 下载最新 Node LTS(SHA-256 校验)→ 安装官方 dsh@latest → 启动 → 打开");
  }
};
main().catch((e) => { console.error(String(e)); process.exit(1); });
