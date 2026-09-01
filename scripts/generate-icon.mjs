import fs from "node:fs";
import zlib from "node:zlib";

const width = 1024, height = 1024, pixels = Buffer.alloc((width * 3 + 1) * height);
const center = [512, 512], radius = 402;
const clamp = value => Math.max(0, Math.min(255, Math.round(value)));
const mix = (a, b, t) => a.map((value, index) => clamp(value + (b[index] - value) * t));
const distance = (x, y) => Math.hypot(x - center[0], y - center[1]);
const circleGlow = (x, y, cx, cy, spread) => Math.max(0, 1 - Math.hypot(x - cx, y - cy) / spread);
const roundedRect = (x, y, left, top, width, height, radius) => {
  const dx = Math.max(left + radius - x, 0, x - (left + width - radius));
  const dy = Math.max(top + radius - y, 0, y - (top + height - radius));
  return Math.hypot(dx, dy) <= radius;
};

for (let y = 0; y < height; y++) {
  const row = y * (width * 3 + 1); pixels[row] = 0;
  for (let x = 0; x < width; x++) {
    const d = distance(x, y);
    let color = [244, 246, 255];
    if (d <= radius) {
      const t = Math.max(0, Math.min(1, (x + y - 160) / 1280));
      color = mix([165, 240, 255], [39, 57, 159], t);
      const violet = circleGlow(x, y, 820, 780, 560);
      const cool = circleGlow(x, y, 190, 190, 420);
      color = mix(color, [194, 143, 242], violet * 0.48);
      color = mix(color, [224, 251, 255], cool * 0.30);
    }
    const bars = [[328, 364, 360], [328, 478, 286], [328, 592, 212]];
    if (bars.some(([left, top, barWidth]) => roundedRect(x, y, left, top, barWidth, 68, 34))) color = [255, 255, 255];
    const i = row + 1 + x * 3; pixels[i] = color[0]; pixels[i + 1] = color[1]; pixels[i + 2] = color[2];
  }
}

const crcTable = Array.from({ length: 256 }, (_, n) => { let c = n; for (let k = 0; k < 8; k++) c = (c & 1) ? 0xedb88320 ^ (c >>> 1) : c >>> 1; return c >>> 0; });
const crc32 = buffer => { let c = 0xffffffff; for (const byte of buffer) c = crcTable[(c ^ byte) & 255] ^ (c >>> 8); return (c ^ 0xffffffff) >>> 0; };
const chunk = (type, data) => { const name = Buffer.from(type), out = Buffer.alloc(data.length + 12); out.writeUInt32BE(data.length, 0); name.copy(out, 4); data.copy(out, 8); out.writeUInt32BE(crc32(Buffer.concat([name, data])), 8 + data.length); return out; };
const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(width, 0); ihdr.writeUInt32BE(height, 4); ihdr[8] = 8; ihdr[9] = 2;
const png = Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk("IHDR", ihdr), chunk("IDAT", zlib.deflateSync(pixels, { level: 9 })), chunk("IEND", Buffer.alloc(0))]);
fs.writeFileSync(new URL("../ios/CodexAccounts/Assets.xcassets/AppIcon.appiconset/AppIcon.png", import.meta.url), png);
