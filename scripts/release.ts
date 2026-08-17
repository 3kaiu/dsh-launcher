// release.ts —— 构建 dshctl 轻量发行包(TS;node >= 24 原生运行,零构建期依赖)
// 用法: node scripts/release.ts <version>
// 产物: dist/dshctl-<version>.zip + SHA256SUMS.txt(约几十 KB,不含运行时)
// 首启: wrapper.sh 自动下载 node 最新 LTS(SHA-256 校验)→ dshctl.ts 原生 TS 运行
// 版本: 全部动态 —— node 取 nodejs.org 最新 LTS,dsh 取 npm latest,不写死
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync, statSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dir = dirname(fileURLToPath(import.meta.url));
const root = join(__dir, "..");
const dist = join(root, "dist");
const version = process.argv[2] ?? "dev";

rmSync(dist, { recursive: true, force: true });
const stage = join(dist, "stage");
mkdirSync(stage, { recursive: true });

console.log("== 1/2 拷贝 TS 源码 + 启动器 + 文档(零构建,node 24+ 原生 TS)");
for (const f of ["src/dshctl.ts", "src/versions.ts", "scripts/wrapper.sh"]) {
  const dst = f.replace(/^src\//, "").replace(/^scripts\//, "");
  mkdirSync(join(stage, dst.includes("/") ? dst.slice(0, dst.lastIndexOf("/")) : "."), { recursive: true });
  const src = join(root, f);
  if (!existsSync(src)) throw new Error("缺失: " + f);
  writeFileSync(join(stage, dst), readFileSync(src));
}
// 包根入口 dshctl(即 wrapper)
writeFileSync(join(stage, "dshctl"), readFileSync(join(root, "scripts", "wrapper.sh")));
// 删除 dist 里误存的旧产物
if (existsSync(join(stage, "dshctl.ts"))) {}
if (existsSync(join(stage, "dshctl.mjs"))) rmSync(join(stage, "dshctl.mjs"));
if (existsSync(join(stage, "versions.ts"))) {}
if (existsSync(join(stage, "node"))) rmSync(join(stage, "node"), { recursive: true });

// chmod
const { spawnSync } = await import("node:child_process");
spawnSync("chmod", ["+x", join(stage, "dshctl")]);

console.log("== 2/2 打包 zip");
for (const f of ["README.md", "scripts/install.sh"]) {
  const src = join(root, f);
  if (existsSync(src)) writeFileSync(join(stage, f.replace(/^scripts\//, "")), readFileSync(src));
}
spawnSync("bash", ["-lc", "cd dist/stage && zip -qr ../dshctl-" + version + ".zip ."]);
const zip = join(dist, "dshctl-" + version + ".zip");
const sum = createHash("sha256").update(readFileSync(zip)).digest("hex");
writeFileSync(join(dist, "SHA256SUMS.txt"), sum + "  dshctl-" + version + ".zip\n");
writeFileSync(join(dist, "VERSIONS.txt"), "轻量包:不含运行时;首次启动自动下载 node 最新 LTS + dsh latest\n");
console.log("产物: dshctl-" + version + ".zip (" + Math.round(statSync(zip).size / 1024) + " KB)");
console.log("SHA256: " + sum);
