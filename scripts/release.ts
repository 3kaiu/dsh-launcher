// release.ts —— 构建 dshctl 便携发行包(TS;node >= 24 原生运行)
// 用法: node scripts/release.ts <version> <arch>  (arch: arm64|x64,默认当前架构)
// 产物: dist/dshctl-macos-<arch>-<version>.zip + SHA256SUMS.txt
// 内容: node(官方最新 LTS 二进制,包内自带 → 用户零配置) + dshctl.mjs(esbuild bundle) + dshctl(启动包装)
// 版本策略: 不写死 —— 构建时取 nodejs.org 最新 LTS;运行时 dshctl 每次启动复查上游,发现新版自动升级到 ~/.local/share/dsh-runtime
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync, statSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dir = dirname(fileURLToPath(import.meta.url));
const root = join(__dir, "..");
const dist = join(root, "dist");
const version = process.argv[2] ?? "dev";
const arch = process.argv[3] ?? process.arch.replace("x86_64", "x64");

function sh(cmd: string, args: string[]): void {
  const r = spawnSync(cmd, args, { cwd: root, stdio: "inherit" });
  if (r.status !== 0) { console.error("失败: " + cmd + " " + args.join(" ")); process.exit(1); }
}

async function latestLts(): Promise<string> {
  const res = await fetch("https://nodejs.org/dist/index.json", { signal: AbortSignal.timeout(15000) });
  if (!res.ok) throw new Error("nodejs.org 不可达");
  const list = (await res.json()) as { version: string; lts: string | false }[];
  const hit = list.find((e) => e.lts !== false);
  if (!hit) throw new Error("无 LTS 版本");
  return hit.version.replace(/^v/, "");
}

console.log("== 1/4 查询 node 最新 LTS(构建包内 node,不写死)");
const nodeVer = await latestLts();
console.log("最新 LTS: v" + nodeVer + " (" + arch + ")");

rmSync(dist, { recursive: true, force: true });
const stage = join(dist, "stage-" + arch);
mkdirSync(stage, { recursive: true });
mkdirSync(join(stage, "node"), { recursive: true });

console.log("== 2/4 下载官方 node v" + nodeVer + " tarball + SHA-256 校验");
const tar = join(dist, "node.tar.gz");
{
  const res = await fetch("https://nodejs.org/dist/v" + nodeVer + "/node-v" + nodeVer + "-darwin-" + arch + ".tar.gz", { signal: AbortSignal.timeout(15 * 60 * 1000) });
  if (!res.ok) throw new Error("下载失败 " + res.status);
  writeFileSync(tar, Buffer.from(await res.arrayBuffer()));
  const sumsRes = await fetch("https://nodejs.org/dist/v" + nodeVer + "/SHASUMS256.txt", { signal: AbortSignal.timeout(30000) });
  if (sumsRes.ok) {
    const expect = (await sumsRes.text()).split("\n").find((l) => l.includes("node-v" + nodeVer + "-darwin-" + arch + ".tar.gz"))?.split(/\s+/)[0];
    if (expect) {
      const actual = createHash("sha256").update(readFileSync(tar)).digest("hex");
      if (actual !== expect) throw new Error("SHA-256 校验失败");
      console.log("SHA-256 校验通过");
    }
  }
  sh("tar", ["-xzf", tar, "-C", join(stage, "node"), "--strip-components=1"]);
  rmSync(tar, { force: true });
}

console.log("== 3/4 esbuild bundle src/dshctl.ts → dshctl.mjs + 启动包装");
sh("npx", ["esbuild", "src/dshctl.ts", "--bundle", "--platform=node", "--format=esm", "--target=node22", "--outfile=" + join(stage, "dshctl.mjs")]);
sh("cp", ["scripts/wrapper.sh", join(stage, "dshctl")]);
sh("chmod", ["+x", join(stage, "dshctl")]);
sh("chmod", ["+x", join(stage, "node", "bin", "node")]);

console.log("== 4/4 打包 zip");
sh("cp", ["README.md", join(stage, "README.md")]);
if (existsSync(join(root, "scripts", "install.sh"))) sh("cp", ["scripts/install.sh", join(stage, "install.sh")]);
if (existsSync(join(root, "launchd", "com.dshlauncher.runtime.plist"))) sh("cp", ["launchd/com.dshlauncher.runtime.plist", join(stage, "com.dshlauncher.runtime.plist")]);
const zipName = "dshctl-macos-" + arch + "-" + version + ".zip";
sh("bash", ["-lc", "cd dist/stage-" + arch + " && zip -qr ../" + zipName + " ."]);
const sum = createHash("sha256").update(readFileSync(join(dist, zipName))).digest("hex");
const sums = existsSync(join(dist, "SHA256SUMS.txt")) ? readFileSync(join(dist, "SHA256SUMS.txt"), "utf8") : "";
writeFileSync(join(dist, "SHA256SUMS.txt"), sums + sum + "  " + zipName + "\n");
writeFileSync(join(dist, "VERSIONS.txt"), "node: v" + nodeVer + " (构建时最新 LTS)\n" + "说明: 运行时每次启动复查上游,自动升级 node 与 dsh\n");
console.log("产物: " + zipName + " (" + Math.round(statSync(join(dist, zipName)).size / 1024) + " KB)");
console.log("包内 node: v" + nodeVer);
console.log("SHA256: " + sum);
