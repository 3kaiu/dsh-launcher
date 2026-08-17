// versions 纯函数单测(node --test;解析逻辑注入固定 JSON,不依赖网络)
import { test } from "node:test";
import assert from "node:assert/strict";
import { parseNodeIndex, parseDshLatest, arch, nodeTarballUrl, nodeShasumsUrl } from "../src/versions.ts";

test("parseNodeIndex:取最新 LTS(跳过非 LTS)", () => {
  const list = [
    { version: "v25.0.0", lts: false },
    { version: "v24.19.0", lts: "Krypton" },
    { version: "v23.11.0", lts: false },
    { version: "v22.24.0", lts: "Jod" },
  ];
  assert.equal(parseNodeIndex(list), "24.19.0");
});
test("parseNodeIndex:全非 LTS 返回 null", () => {
  assert.equal(parseNodeIndex([{ version: "v25.0.0", lts: false }]), null);
});
test("parseDshLatest:取 version 字段", () => {
  assert.equal(parseDshLatest({ version: "0.1.0-rc.6" }), "0.1.0-rc.6");
  assert.equal(parseDshLatest({}), null);
});
test("URL 构造", () => {
  assert.equal(nodeTarballUrl("24.19.0", "arm64"), "https://nodejs.org/dist/v24.19.0/node-v24.19.0-darwin-arm64.tar.gz");
  assert.equal(nodeTarballUrl("24.19.0", "x64"), "https://nodejs.org/dist/v24.19.0/node-v24.19.0-darwin-x64.tar.gz");
  assert.equal(nodeShasumsUrl("24.19.0"), "https://nodejs.org/dist/v24.19.0/SHASUMS256.txt");
});
test("arch 返回当前架构(arm64|x64)", () => {
  assert.ok(["arm64", "x64"].includes(arch()));
});
