// versions.ts —— 上游版本动态解析(不写死版本,始终跟随上游最新)
// node:nodejs.org/dist/index.json 最新 LTS;dsh:npm registry latest tag
export type Arch = "arm64" | "x64";

export function arch(): Arch { return process.arch === "arm64" ? "arm64" : "x64"; }

/** 解析 nodejs.org/dist/index.json:返回最新 LTS 版本号(如 "24.19.0"),无则 null */
export function parseNodeIndex(list: { version: string; lts: string | false | null }[]): string | null {
  const hit = list.find((e) => e.lts !== false && e.lts !== null);
  return hit ? hit.version.replace(/^v/, "") : null;
}

/** 解析 npm registry latest:返回版本号(如 "0.1.0-rc.6") */
export function parseDshLatest(j: { version?: string }): string | null {
  return j?.version ?? null;
}

/** 拉取 node 最新 LTS(网络失败返回 null,调用方回退本地版本) */
export async function nodeLatestLts(): Promise<string | null> {
  try {
    const res = await fetch("https://nodejs.org/dist/index.json", { signal: AbortSignal.timeout(5000) });
    if (!res.ok) return null;
    return parseNodeIndex((await res.json()) as { version: string; lts: string | false | null }[]);
  } catch { return null; }
}

/** 拉取 @deepseek-ai/dsh 最新版(网络失败返回 null) */
export async function dshLatest(): Promise<string | null> {
  try {
    const res = await fetch("https://registry.npmjs.org/@deepseek-ai/dsh/latest", { signal: AbortSignal.timeout(5000) });
    if (!res.ok) return null;
    return parseDshLatest((await res.json()) as { version?: string });
  } catch { return null; }
}

export function nodeTarballUrl(ver: string, a: Arch): string {
  return "https://nodejs.org/dist/v" + ver + "/node-v" + ver + "-darwin-" + a + ".tar.gz";
}
export function nodeShasumsUrl(ver: string): string {
  return "https://nodejs.org/dist/v" + ver + "/SHASUMS256.txt";
}
