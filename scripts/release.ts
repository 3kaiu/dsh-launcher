// release.ts —— 构建 dshctl 发行包 + macOS 双击 App(dmg)(TS;node >= 24 原生运行)
// 用法: node scripts/release.ts <version>
// 产物(dist/):
//   dshctl-<ver>.zip           命令行版(~11KB,零依赖,TS 原生运行)
//   dsh-launcher-<ver>.dmg     双击版(仅 macOS:内含 DeepSeek Harness Launcher.app)
//   SHA256SUMS.txt / VERSIONS.txt
// 版本:全部动态 —— node 取 nodejs.org 最新 LTS,dsh 取 npm latest,不写死
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync, statSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const __dir = dirname(fileURLToPath(import.meta.url));
const root = join(__dir, "..");
const dist = join(root, "dist");
const version = process.argv[2] ?? "dev";
const isMac = process.platform === "darwin";
const APP_NAME = "DeepSeek Harness Launcher";
const APP_ID = "com.dshlauncher.app";

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
writeFileSync(join(stage, "README.md"), readFileSync(join(root, "README.md")));
sh("chmod", ["+x", join(stage, "dshctl")]);
sh("bash", ["-lc", "cd dist/stage && zip -qr ../dshctl-" + version + ".zip ."]);

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
  // 图标:node 生成 1024 PNG → sips iconset → iconutil icns
  const iconPng = join(dist, "icon-1024.png");
  sh("node", ["tools/gen-icon.mjs", iconPng]);
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
  // dmg
  console.log("== 3/3 打包 dmg");
  dmgPath = join(dist, "dsh-launcher-" + version + ".dmg");
  sh("hdiutil", ["create", "-volname", "dsh-launcher-" + version, "-srcfolder", app, "-ov", "-format", "UDZO", dmgPath]);
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
writeFileSync(join(dist, "VERSIONS.txt"), "轻量包:不含运行时;首次启动自动下载 node 最新 LTS + dsh latest" + String.fromCharCode(10));
console.log("产物:");
if (dmgPath && existsSync(dmgPath)) console.log("  dsh-launcher-" + version + ".dmg (" + Math.round(statSync(dmgPath).size / 1024) + " KB) — 双击安装");
console.log("  dshctl-" + version + ".zip (" + Math.round(statSync(join(dist, "dshctl-" + version + ".zip")).size / 1024) + " KB) — 命令行版");
