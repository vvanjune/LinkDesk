"""Encode rendered PNG sizes as native ICNS and ICO assets (Python stdlib)."""
from pathlib import Path
import struct
import sys

folder = Path(sys.argv[1])
destination = Path(sys.argv[2])
destination.mkdir(parents=True, exist_ok=True)
sizes = [16, 32, 48, 64, 128, 256]
images = [(folder / f"icon-{size}.png").read_bytes() for size in sizes]
offset = 6 + 16 * len(images)
entries = []
for size, image in zip(sizes, images):
    entries.append(struct.pack("<BBBBHHII", size % 256, size % 256, 0, 0, 1, 32, len(image), offset))
    offset += len(image)
(destination / "LinkDesk.ico").write_bytes(struct.pack("<HHH", 0, 1, len(images)) + b"".join(entries) + b"".join(images))
chunks = []
for code, file in [("icp4", "icon-16.png"), ("icp5", "icon-32.png"), ("icp6", "icon-64.png"), ("ic07", "icon-128.png"), ("ic08", "icon-256.png"), ("ic09", "LinkDesk.iconset/icon_512x512.png"), ("ic10", "LinkDesk.png")]:
    data = (folder / file).read_bytes()
    chunks.append(code.encode("ascii") + struct.pack(">I", len(data) + 8) + data)
body = b"".join(chunks)
(destination / "LinkDesk.icns").write_bytes(b"icns" + struct.pack(">I", len(body) + 8) + body)
(destination / "LinkDesk.png").write_bytes((folder / "LinkDesk.png").read_bytes())
