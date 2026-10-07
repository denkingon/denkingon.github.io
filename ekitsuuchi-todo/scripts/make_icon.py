#!/usr/bin/env python3
"""AppIcon.png (1024x1024) を標準ライブラリだけで生成する。
黒地に細い白リング（ジオフェンスの円）と中心の白い点。グレースケールのみ・アルファ無し
（App Store のアイコンはアルファを持てない）。再生成: python3 scripts/make_icon.py
"""
import math
import os
import struct
import sys
import zlib

SIZE = 1024
CENTER = (SIZE - 1) / 2.0
RING_OUTER = 372.0   # 余白を広めに取る（角丸マスクで切られても円が欠けない）
RING_INNER = 354.0
DOT_RADIUS = 44.0


def clamp01(v):
    return 0.0 if v < 0.0 else 1.0 if v > 1.0 else v


def coverage(d):
    # 中心からの距離 d の画素の白さ。端は 1px 幅の線形ランプでアンチエイリアス。
    ring = min(clamp01(d - RING_INNER + 0.5), clamp01(RING_OUTER - d + 0.5))
    dot = clamp01(DOT_RADIUS - d + 0.5)
    return max(ring, dot)


def png_rgb(width, height, rows):
    def chunk(tag, data):
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    raw = b"".join(b"\x00" + row for row in rows)  # 各行の filter type 0
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)  # 8bit RGB（R=G=B でグレー）
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    out = os.path.join(here, "..", "App", "Resources", "Assets.xcassets", "AppIcon.appiconset", "AppIcon.png")
    if len(sys.argv) > 1:
        out = sys.argv[1]
    rows = []
    for y in range(SIZE):
        dy = y - CENTER
        row = bytearray()
        for x in range(SIZE):
            d = math.hypot(x - CENTER, dy)
            v = int(round(255 * coverage(d)))
            row += bytes((v, v, v))
        rows.append(bytes(row))
    with open(out, "wb") as f:
        f.write(png_rgb(SIZE, SIZE, rows))
    print("wrote", os.path.normpath(out))


if __name__ == "__main__":
    main()
