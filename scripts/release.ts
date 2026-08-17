// release.ts —— 构建 dshctl 发行包 + macOS 双击 App(dmg)(TS;node >= 24 原生运行)
// 用法: node scripts/release.ts <version>
// 产物(dist/):
//   dshctl-<ver>.zip           命令行版(~11KB,零依赖,TS 原生运行)
//   dsh-launcher-<ver>.dmg     双击版(仅 macOS:内含 DeepSeek Harness Launcher.app)
//   SHA256SUMS.txt / VERSIONS.txt
// 版本:全部动态 —— node 取 nodejs.org 最新 LTS,dsh 取 npm latest,不写死
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync, statSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const __dir = dirname(fileURLToPath(import.meta.url));
const root = join(__dir, "..");
const dist = join(root, "dist");
const version = process.argv[2] ?? "dev";
const isMac = process.platform === "darwin";
const APP_NAME = "DeepSeek Harness";
const APP_ID = "com.dshlauncher.app";

/** 解析 nodejs.org 最新 LTS(网络失败回退固定版本,仅影响构建时打包) */
async function latestNodeLts(): Promise<string> {
  try {
    const res = await fetch("https://nodejs.org/dist/index.json", { signal: AbortSignal.timeout(15000) });
    if (!res.ok) return "24.19.0";
    const list = (await res.json()) as { version: string; lts: string | false | null }[];
    return list.find((e) => e.lts !== false && e.lts !== null)?.version.replace(/^v/, "") ?? "24.19.0";
  } catch { return "24.19.0"; }
}

async function main() {

function sh(cmd: string, args: string[], cwd?: string): boolean {
  const r = spawnSync(cmd, args, { cwd: cwd ?? root, stdio: "inherit" });
  return r.status === 0;
}

rmSync(dist, { recursive: true, force: true });
const stage = join(dist, "stage");
mkdirSync(stage, { recursive: true });

// ---- 命令行版(跨平台) ----
console.log("== 1/3 命令行包(TS 源码,零构建)");
for (const [src, dst] of [
  ["src/dshctl.ts", "dshctl.ts"],
  ["src/versions.ts", "versions.ts"],
  ["scripts/wrapper.sh", "wrapper.sh"],
]) {
  writeFileSync(join(stage, dst), readFileSync(join(root, src)));
}
writeFileSync(join(stage, "dshctl"), readFileSync(join(root, "scripts", "wrapper.sh")));
writeFileSync(join(stage, "install.sh"), readFileSync(join(root, "scripts", "install.sh")));
sh("chmod", ["+x", join(stage, "dshctl")]);
sh("zip", ["-qr", join(dist, "dshctl-" + version + ".zip"), "."], stage);

// ---- macOS 双击 App + dmg ----
let dmgPath: string | null = null;
if (isMac) {
  console.log("== 2/3 macOS 双击 App(" + APP_NAME + ".app)");
  const app = join(stage, APP_NAME + ".app");
  const macosDir = join(app, "Contents", "MacOS");
  const resDir = join(app, "Contents", "Resources");
  mkdirSync(macosDir, { recursive: true });
  mkdirSync(resDir, { recursive: true });
  // Info.plist
  const plist = [
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
    '<plist version="1.0">',
    '<dict>',
    "  <key>CFBundleName</key><string>" + APP_NAME + "</string>",
    "  <key>CFBundleDisplayName</key><string>" + APP_NAME + "</string>",
    "  <key>CFBundleIdentifier</key><string>" + APP_ID + "</string>",
    "  <key>CFBundleVersion</key><string>" + version + "</string>",
    "  <key>CFBundleShortVersionString</key><string>" + version + "</string>",
    "  <key>CFBundleExecutable</key><string>Launcher</string>",
    "  <key>CFBundlePackageType</key><string>APPL</string>",
    "  <key>LSMinimumSystemVersion</key><string>13.0</string>",
    "  <key>NSHighResolutionCapable</key><true/>",
    "  <key>CFBundleIconFile</key><string>icon</string>",
    "</dict>",
    "</plist>",
    "",
  ].join(String.fromCharCode(10));
  writeFileSync(join(app, "Contents", "Info.plist"), plist);
  // 启动器 + 资源
  writeFileSync(join(macosDir, "Launcher"), readFileSync(join(root, "scripts", "launcher.sh")));
  sh("chmod", ["+x", join(macosDir, "Launcher")]);
  for (const f of ["wrapper.sh", "dshctl.ts", "versions.ts"]) {
    const base = f.endsWith(".ts") ? "src" : "scripts";
    writeFileSync(join(resDir, f), readFileSync(join(root, base, f)));
    if (f.endsWith(".sh")) sh("chmod", ["+x", join(resDir, f)]);
  }
  // 内置精简 node 最新 LTS(仅 bin/node + bin/npm + lib/node_modules/npm,首次引导免下载)
  {
    const nodeVer = await latestNodeLts();
    const nodeArch = process.arch === "arm64" ? "arm64" : "x64";
    // tarball 缓存到 .cache/(dist 每次清空),重复构建不再重新下载
    const cacheDir = join(root, ".cache");
    mkdirSync(cacheDir, { recursive: true });
    const tar = join(cacheDir, "node-v" + nodeVer + "-darwin-" + nodeArch + ".tar.gz");
    const tmp = join(dist, "node-extract");
    rmSync(tmp, { recursive: true, force: true });
    mkdirSync(tmp, { recursive: true });
    if (existsSync(tar)) {
      console.log("  (内置 node: v" + nodeVer + " 已缓存,跳过下载)");
    } else {
      console.log("  (内置 node: 下载 v" + nodeVer + " darwin-" + nodeArch + " ...)");
      const dl = spawnSync("curl", ["-fSL", "--max-time", "900", "-o", tar, "https://nodejs.org/dist/v" + nodeVer + "/node-v" + nodeVer + "-darwin-" + nodeArch + ".tar.gz"], { stdio: "inherit" });
      if (dl.status !== 0) { rmSync(tar, { force: true }); console.error("  (警告: node 下载失败,首次启动时将自动下载)"); }
    }
    if (existsSync(tar)) {
      const sums = spawnSync("curl", ["-fsS", "--max-time", "60", "https://nodejs.org/dist/v" + nodeVer + "/SHASUMS256.txt"], { encoding: "utf8" });
      const expect = (sums.stdout ?? "").split("\n").find((l) => l.includes("node-v" + nodeVer + "-darwin-" + nodeArch + ".tar.gz"))?.split(/\s+/)[0];
      const actual = createHash("sha256").update(readFileSync(tar)).digest("hex");
      if (!expect || actual !== expect) {
        console.error("  (警告: SHA-256 校验失败,不打包 node,首次启动自动下载)");
      } else if (!sh("tar", ["-xzf", tar, "-C", tmp, "--strip-components=1"])) {
        console.error("  (警告: 解压失败,首次启动自动下载)");
      } else {
        // 精简:只保留运行所需(bin/node + bin/npm + lib/node_modules/npm)
        // 注意:bin/npm 是符号链接,cp 必须用 -P 保留,否则 require 相对路径失效
        const nodeDir = join(resDir, "node");
        const binDir = join(nodeDir, "bin");
        mkdirSync(binDir, { recursive: true });
        for (const f of ["node", "npm"]) {
          sh("cp", ["-P", join(tmp, "bin", f), join(binDir, f)]);
          sh("chmod", ["+x", join(binDir, f)]);
        }
        for (const f of ["lib/node_modules/npm", "LICENSE"]) {
          const from = join(tmp, f);
          if (existsSync(from)) {
            const to = join(nodeDir, f);
            mkdirSync(dirname(to), { recursive: true });
            sh("cp", ["-R", from, to]);
          }
        }
        const probe = spawnSync(join(nodeDir, "bin", "node"), ["--version"], { encoding: "utf8" });
        if (probe.status === 0) console.log("  (已内置精简 node " + probe.stdout.trim() + " → Resources/node)");
        else { rmSync(nodeDir, { recursive: true, force: true }); console.error("  (警告: 内置 node 校验失败,首次启动自动下载)"); }
      }
    }
    rmSync(tmp, { recursive: true, force: true });
  }
  // 内置已安装的 dsh 官方运行时(Resources/app):双击零下载、离线可用
  {
    const appDir = join(resDir, "app");
    if (!existsSync(join(resDir, "node", "bin", "node"))) {
      console.error("  (警告: 无内置 node,跳过 dsh 预装,首次启动将 npm 安装)");
    } else {
      mkdirSync(appDir, { recursive: true });
      writeFileSync(join(appDir, "package.json"), JSON.stringify({ name: "dsh-runtime-app", private: true, dependencies: { "@deepseek-ai/dsh": "latest" } }, null, 2) + "\n");
      console.log("  (预装官方 dsh@latest: npm install,约 1-3 分钟)");
      const r = spawnSync(join(resDir, "node", "bin", "npm"), ["install", "--no-audit", "--no-fund", "--loglevel=error"], { cwd: appDir, env: { ...process.env, PATH: join(resDir, "node", "bin") + ":" + process.env.PATH }, stdio: "inherit" });
      const pkg = join(appDir, "node_modules", "@deepseek-ai", "dsh", "package.json");
      if (r.status === 0 && existsSync(pkg)) {
        const ver = (JSON.parse(readFileSync(pkg, "utf8")) as { version: string }).version;
        // 剪除其他平台的原生预编译与 Windows 构建源码(如 node-pty 的 win32 PDB,~58MB)
        const nodeArchName = process.arch === "arm64" ? "arm64" : "x64";
        const ptyDir = join(appDir, "node_modules", "node-pty");
        for (const sub of ["prebuilds", "third_party", "deps"]) {
          const p = join(ptyDir, sub);
          if (existsSync(p)) {
            for (const entry of readdirSync(p)) {
              if (sub === "prebuilds" && entry === "darwin-" + nodeArchName) continue;
              rmSync(join(p, entry), { recursive: true, force: true });
            }
          }
        }
        const probe = spawnSync(join(resDir, "node", "bin", "node"), ["-e", "require(process.argv[1]);console.log('pty ok')", join(appDir, "node_modules", "node-pty", "lib", "index.js")], { encoding: "utf8" });
        if (probe.status === 0) console.log("  (已剪除其他平台原生预编译,node-pty 校验通过)");
        else console.error("  (警告: node-pty 校验失败,终端功能可能异常)");
        // 剪除运行时永不加载的 sourcemap(约 7.6M)、README/文档(.md)、测试目录与 .DS_Store
        const walk = (dir: string): void => {
          for (const e of readdirSync(dir, { withFileTypes: true })) {
            const p = join(dir, e.name);
            if (e.isDirectory()) {
              if (e.name === "test" || e.name === "tests" || e.name === "__tests__") { rmSync(p, { recursive: true, force: true }); continue; }
              walk(p);
            } else if (e.name.endsWith(".map") || e.name.endsWith(".md") || e.name === ".DS_Store") rmSync(p, { force: true });
          }
        };
        walk(join(appDir, "node_modules"));
        // 剪除遥测依赖:40K 的 dsh-session-telemetry-otel 插件拖入整个 @opentelemetry 树(21M),
        // 启动环境已设官方开关 DSH_TELEMETRY_DISABLED=1,插件不会被加载,纯属磁盘占用
        for (const sub of ["@opentelemetry", "@deepseek-ai/dsh-session-telemetry-otel"]) {
          rmSync(join(appDir, "node_modules", sub), { recursive: true, force: true });
        }
        for (const d of [join(resDir, "node", "lib", "node_modules", "npm", "man"), join(resDir, "node", "lib", "node_modules", "npm", "html")]) {
          rmSync(d, { recursive: true, force: true });
        }
        console.log("  (已剪除 sourcemap 与 npm 文档)");
        console.log("  (已预装 dsh " + ver + " → Resources/app,双击即用,离线可用)");
      } else {
        rmSync(appDir, { recursive: true, force: true });
        console.error("  (警告: dsh 预装失败,首次启动将自动安装)");
      }
    }
  }
  // 图标:构建时从官方 CDN 实时拉取(上游更新自动跟随)→ fallback 本地入库图 → svg(rsvg)→ 占位图
  let iconPng = join(dist, "icon.svg.png");
  const iconUrl = "https://cdn.deepseek.com/platform/favicon.png";
  const cdnTmp = join(dist, "icon-cdn.png");
  const dl = spawnSync("curl", ["-fsSL", "--max-time", "15", "-o", cdnTmp, iconUrl]);
  if (dl.status === 0 && existsSync(cdnTmp)) {
    iconPng = join(dist, "icon.png");
    sh("sips", ["-z", "1024", "1024", cdnTmp, "--out", iconPng]);
    console.log("  (图标:CDN 实时下载 " + iconUrl + ")");
  } else if (existsSync(join(root, "assets", "icon.png"))) {
    iconPng = join(dist, "icon.png");
    sh("sips", ["-z", "1024", "1024", join(root, "assets", "icon.png"), "--out", iconPng]);
    console.log("  (图标:回退本地 assets/icon.png)");
  } else if (existsSync(join(root, "assets", "icon.svg"))) {
    sh("rsvg-convert", ["-w", "1024", "-h", "1024", join(root, "assets", "icon.svg"), "-o", iconPng]);
    console.log("  (图标:官方 favicon.svg)");
  } else {
    console.log("  (无官方图标,fallback gen-icon.mjs 占位图)");
    sh("node", ["tools/gen-icon.mjs", iconPng]);
  }
  const iconset = join(dist, "icon.iconset");
  rmSync(iconset, { recursive: true, force: true });
  mkdirSync(iconset, { recursive: true });
  const sizes: [number, string][] = [
    [16, "icon_16x16.png"], [32, "icon_16x16@2x.png"],
    [32, "icon_32x32.png"], [64, "icon_32x32@2x.png"],
    [128, "icon_128x128.png"], [256, "icon_128x128@2x.png"],
    [256, "icon_256x256.png"], [512, "icon_256x256@2x.png"],
    [512, "icon_512x512.png"],
  ];
  for (const [sz, name] of sizes) sh("sips", ["-z", String(sz), String(sz), iconPng, "--out", join(iconset, name)]);
  writeFileSync(join(iconset, "icon_512x512@2x.png"), readFileSync(iconPng));
  sh("iconutil", ["-c", "icns", iconset, "-o", join(resDir, "icon.icns")]);
  // ad-hoc 签名(减少"无法验证开发者"提示)
  sh("codesign", ["--force", "-s", "-", "--deep", app]);
  // dmg:App + 应用程序快捷方式(拖入即安装)。ci 模式只产出 stage 供冒烟,跳过打包,避免与 Release 重复构建
  if (version !== "ci") {
    console.log("== 3/3 打包 dmg(App + Applications 快捷方式)");
    const dmgSrc = join(dist, "dmg-src");
    rmSync(dmgSrc, { recursive: true, force: true });
    mkdirSync(dmgSrc, { recursive: true });
    sh("cp", ["-R", app, dmgSrc]);
    sh("ln", ["-s", "/Applications", join(dmgSrc, "Applications")]);
    dmgPath = join(dist, "dsh-launcher-" + version + ".dmg");
    // UDZO(zlib-level 9):zlib 编码器跨 macOS 版本一致,CI 与本地产物可复现。
    // 不用 ULMO(LZMA):其压缩率随 macOS 点版本编码器浮动(实测 26.5 本地 121MB,
    // 而 CI macos-26 镜像同内容同参数 175MB,差 40%),发布产物不可预测。
    sh("hdiutil", ["create", "-volname", "dsh-launcher-" + version, "-srcfolder", dmgSrc, "-ov", "-format", "UDZO", "-imagekey", "zlib-level=9", dmgPath]);
  } else {
    console.log("== 3/3 跳过 dmg 打包(CI 冒烟模式,仅 stage)");
  }
} else {
  console.log("== 2/3 跳过 App/dmg(非 macOS,仅构建命令行包)");
  console.log("== 3/3 打包完成(命令行版)");
}

// ---- 校验与清单 ----
const sums: string[] = [];
for (const f of ["dshctl-" + version + ".zip"]) {
  const p = join(dist, f);
  if (existsSync(p)) sums.push(createHash("sha256").update(readFileSync(p)).digest("hex") + "  " + f);
}
if (dmgPath && existsSync(dmgPath)) sums.push(createHash("sha256").update(readFileSync(dmgPath)).digest("hex") + "  " + "dsh-launcher-" + version + ".dmg");
writeFileSync(join(dist, "SHA256SUMS.txt"), sums.join(String.fromCharCode(10)) + String.fromCharCode(10));
writeFileSync(join(dist, "VERSIONS.txt"), "dmg 版:内置精简 node LTS + 预装官方 dsh,离线即用;命令行版:首次 start 自动下载最新 node LTS + dsh latest" + String.fromCharCode(10));
console.log("产物:");
if (dmgPath && existsSync(dmgPath)) console.log("  dsh-launcher-" + version + ".dmg (" + Math.round(statSync(dmgPath).size / 1024) + " KB,内含 node LTS) — 双击安装");
console.log("  dshctl-" + version + ".zip (" + Math.round(statSync(join(dist, "dshctl-" + version + ".zip")).size / 1024) + " KB) — 命令行版");
}
main().catch((e) => { console.error(e); process.exit(1); });
