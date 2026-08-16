#!/usr/bin/env node
// 生成 dsh-launcher 图标 (1024x1024 PNG,纯 Node 零依赖)
// 用法: node tools/gen-icon.mjs [输出路径]
import zlib from "node:zlib";
import fs from "node:fs";

const OUT = process.argv[2] || "icon-1024.png";
const S = 1024;
const SS = 2; // 2x2 超采样抗锯齿

// ---- PNG 编码 ----
const CRC_TABLE = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c >>> 0;
  }
  return t;
})();

function crc32(buf) {
  let c = 0xffffffff;
  for (let i = 0; i < buf.length; i++) c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function chunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length);
  const body = Buffer.concat([Buffer.from(type, "ascii"), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(body));
  return Buffer.concat([len, body, crc]);
}

// ---- 绘制 ----
const lerp = (a, b, t) => a + (b - a) * t;
const mix = (c1, c2, t) => [lerp(c1[0], c2[0], t), lerp(c1[1], c2[1], t), lerp(c1[2], c2[2], t)];

const BG_TOP = [15, 23, 42];      // 深蓝黑
const BG_BOTTOM = [30, 58, 138];  // 深蓝
const TILE_TOP = [96, 165, 250];  // 亮蓝
const TILE_BOTTOM = [37, 99, 235];// 蓝
const CHEVRON = [255, 255, 255];  // 白
const CURSOR = [191, 219, 254];   // 浅蓝

function segDist(px, py, x1, y1, x2, y2) {
  const dx = x2 - x1, dy = y2 - y1;
  const len2 = dx * dx + dy * dy;
  let t = len2 ? ((px - x1) * dx + (py - y1) * dy) / len2 : 0;
  t = Math.max(0, Math.min(1, t));
  return Math.hypot(px - (x1 + t * dx), py - (y1 + t * dy));
}

function roundedRectDist(px, py, cx, cy, half, r) {
  const dx = Math.abs(px - cx) - (half - r);
  const dy = Math.abs(py - cy) - (half - r);
  return Math.hypot(Math.max(dx, 0), Math.max(dy, 0)) + Math.min(Math.max(dx, dy), 0) - r;
}

function sample(x, y) {
  let c = mix(BG_TOP, BG_BOTTOM, y / S);
  const d = roundedRectDist(x, y, S / 2, S / 2, 300, 150);
  if (d < 0) {
    c = mix(TILE_TOP, TILE_BOTTOM, y / S);
    // 白色双箭头(终端提示符 >)
    const t1 = segDist(x, y, 330, 420, 690, 512);
    const t2 = segDist(x, y, 690, 512, 330, 604);
    if (Math.min(t1, t2) < 26) c = CHEVRON;
    // 光标小方块
    if (x >= 300 && x <= 356 && y >= 660 && y <= 716) c = CURSOR;
  }
  return c;
}

const raw = Buffer.alloc(S * (1 + S * 3));
for (let y = 0; y < S; y++) {
  raw[y * (1 + S * 3)] = 0; // filter none
  for (let x = 0; x < S; x++) {
    let r = 0, g = 0, b = 0;
    for (let sy = 0; sy < SS; sy++) {
      for (let sx = 0; sx < SS; sx++) {
        const [pr, pg, pb] = sample(x + (sx + 0.5) / SS, y + (sy + 0.5) / SS);
        r += pr; g += pg; b += pb;
      }
    }
    const n = SS * SS;
    const off = y * (1 + S * 3) + 1 + x * 3;
    raw[off] = Math.round(r / n);
    raw[off + 1] = Math.round(g / n);
    raw[off + 2] = Math.round(b / n);
  }
}

const ihdr = Buffer.alloc(13);
ihdr.writeUInt32BE(S, 0);
ihdr.writeUInt32BE(S, 4);
ihdr[8] = 8; // bit depth
ihdr[9] = 2; // color type: RGB

const png = Buffer.concat([
  Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
  chunk("IHDR", ihdr),
  chunk("IDAT", zlib.deflateSync(raw)),
  chunk("IEND", Buffer.alloc(0)),
]);
fs.writeFileSync(OUT, png);
console.log("icon written: " + OUT + " (" + png.length + " bytes, " + S + "x" + S + ")");
