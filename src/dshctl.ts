#!/usr/bin/env node
// dshctl.ts —— DeepSeek Harness 运行时管理器(TypeScript;构建为 SEA 单文件可执行,零依赖运行)
// 生命周期: install / start / stop / restart / status / logs / open / update / watch / doctor
// 设计原则: 官方 dsh 零修改零 fork;node 与 dsh 版本不写死——每次运行跟随上游最新
//           (node = nodejs.org 最新 LTS,dsh = npm latest);按需启动,不用时零进程
import { spawn, execSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { arch, nodeLatestLts, dshLatest, nodeTarballUrl, nodeShasumsUrl } from "./versions.ts";
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
const DSH_BIN = join(APP_DIR, "node_modules", "@deepseek-ai", "dsh", "lib", "bin.js");
const VERSIONS_FILE = join(RT_HOME, "versions.json");
const PID_FILE = join(RT_STATE, "dsh.pid");
const LOG_DIR = join(RT_STATE, "logs");
const URL = "http://" + HOST + ":" + PORT;

interface Versions { node?: string; dsh?: string; installedAt?: string; }

function readVersions(): Versions { try { return JSON.parse(readFileSync(VERSIONS_FILE, "utf8")) as Versions; } catch { return {}; } }
function writeVersions(v: Versions) { mkdirSync(RT_HOME, { recursive: true }); writeFileSync(VERSIONS_FILE, JSON.stringify({ ...v, installedAt: new Date().toISOString() }, null, 2) + "\n"); }

async function healthy(): Promise<boolean> {
  try { const res = await fetch(URL, { signal: AbortSignal.timeout(2000) }); return res.ok; } catch { return false; }
}
function pidAlive(pid: number): boolean { if (!pid) return false; try { process.kill(pid, 0); return true; } catch { return false; } }
function readPid(): number { try { return Number(readFileSync(PID_FILE, "utf8")) || 0; } catch { return 0; } }

async function waitReady(seconds: number, log?: string): Promise<boolean> {
  const deadline = Date.now() + seconds * 1000;
  while (Date.now() < deadline) {
    if (await healthy()) return true;
    if (log && !pidAlive(readPid())) break;
    await new Promise((r) => setTimeout(r, 1000));
  }
  return false;
}

function run(cmd: string, args: string[], opts: { cwd?: string; env?: NodeJS.ProcessEnv; stdio?: "inherit" | "pipe" } = {}): { code: number; out: string } {
  const res = spawnSync2(cmd, args, opts);
  return res;
}
import { spawnSync } from "node:child_process";
function spawnSync2(cmd: string, args: string[], opts: { cwd?: string; env?: NodeJS.ProcessEnv; stdio?: "inherit" | "pipe" }): { code: number; out: string } {
  const r = spawnSync(cmd, args, { cwd: opts.cwd, env: opts.env ? { ...process.env, ...opts.env } : process.env, stdio: opts.stdio === "inherit" ? "inherit" : ["ignore", "pipe", "pipe"], encoding: "utf8" });
  return { code: r.status ?? -1, out: (r.stdout ?? "") + (r.stderr ?? "") };
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
    writeFileSync(tar, Buffer.from(await res.arrayBuffer()));
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
    const pkg = JSON.parse(readFileSync(join(APP_DIR, "node_modules", "@deepseek-ai", "dsh", "package.json"), "utf8")) as { version: string };
    writeVersions({ ...readVersions(), dsh: pkg.version });
    console.log("dsh " + pkg.version + " 安装完成 (" + APP_DIR + ")");
    return true;
  } catch (e) { console.error("dsh 安装失败: " + (e as Error).message); return false; }
}

async function ensureRuntime(): Promise<boolean> {
  const v = readVersions();
  const [nodeLts, dshLatestV] = await Promise.all([nodeLatestLts(), dshLatest()]);
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
  } else if (!existsSync(DSH_BIN)) {
    if (!installDsh()) return false;
  }
  return true;
}

// ---------- 生命周期 ----------
async function cmdStart(autoOpen = true): Promise<number> {
  if (await healthy()) { console.log("DeepSeek Harness 已在运行: " + URL); return 0; }
  if (!existsSync(NODE_BIN) || !existsSync(DSH_BIN)) {
    console.log("首次使用:自动安装运行时(跟随上游最新)...");
    if (!(await ensureRuntime())) return 1;
  } else {
    await ensureRuntime(); // 在线检查上游最新,有新版自动升级
  }
  mkdirSync(LOG_DIR, { recursive: true });
  const log = join(LOG_DIR, "dsh-" + new Date().toISOString().replace(/[:.]/g, "-").slice(0, 19) + ".log");
  console.log("启动 dsh web (host=" + HOST + " port=" + PORT + "),日志: " + log);
  const fd = (await import("node:fs")).openSync(log, "a");
  const child = spawn(NODE_BIN, [DSH_BIN, "web", "--host", HOST, "--port", String(PORT)], {
    detached: true, stdio: ["ignore", fd, fd], env: { ...process.env, DSH_HOME, PATH: NODE_DIR + "/bin:" + process.env.PATH },
  });
  child.unref();
  writeFileSync(PID_FILE, String(child.pid));
  if (await waitReady(120, log)) {
    console.log("已就绪: " + URL);
    if (autoOpen && process.env.DSHCTL_NO_OPEN !== "1") {
      try { execSync("open " + URL); console.log("已打开: " + URL); } catch { console.log("请手动打开: " + URL); }
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
  console.log("  dsh:  " + (v.dsh ?? "未安装") + (existsSync(DSH_BIN) ? "" : "(缺失)"));
  console.log("  pid:  " + (pidAlive(pid) ? pid : "-"));
  return ok ? 0 : 1;
}

async function cmdOpen(): Promise<number> {
  if (!(await healthy())) { console.log("未运行,先启动..."); if ((await cmdStart(false)) !== 0) return 1; }
  try { execSync("open " + URL); console.log("已打开: " + URL); } catch { console.log("请手动打开: " + URL); }
  return 0;
}

async function cmdLogs(): Promise<number> {
  const logs = (await import("node:fs")).readdirSync(LOG_DIR).sort().slice(-3);
  if (!logs.length) { console.log("暂无日志"); return 0; }
  execSync("tail -n 50 " + logs.map((f) => join(LOG_DIR, f)).join(" "), { stdio: "inherit" });
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
  console.log("  dsh:  " + (v.dsh ?? "-") + " " + (existsSync(DSH_BIN) ? "✅" : "❌ 缺失"));
  console.log("  进程: " + (ok ? "✅ " + URL : "未运行"));
  return existsSync(NODE_BIN) && existsSync(DSH_BIN) ? 0 : 1;
}

const cmd = process.argv[2] ?? "help";
const main = async () => {
  switch (cmd) {
    case "install": await ensureRuntime(); break;
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
