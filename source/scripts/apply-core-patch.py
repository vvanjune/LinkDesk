"""Apply LinkDesk's auditable Windows display patch to pinned Deskflow 1.27.0."""
from pathlib import Path
import argparse, re, subprocess, tempfile
p=argparse.ArgumentParser();p.add_argument('source',type=Path);args=p.parse_args()
patch=Path(__file__).resolve().parent.parent/'core-patches/windows-display-safety.patch'
source=args.source.resolve()
# Windows Git checkouts can use CRLF. Normalize only the exact patched files,
# then retain git apply's strict context checks rather than relaxing the patch.
patch_text=patch.read_text(encoding='utf-8')
originals={}
for name in re.findall(r'^--- a/(.+)$',patch_text,re.MULTILINE):
    target=(source/name).resolve()
    if not target.is_relative_to(source):
        raise ValueError('Patch path escapes upstream source')
    originals[target]=target.read_bytes()
try:
    for target, data in originals.items():
        target.write_bytes(data.replace(b'\r\n',b'\n'))
    with tempfile.TemporaryDirectory() as temporary:
        normalized=Path(temporary)/'display-safety.patch'
        normalized.write_bytes(patch_text.encode('utf-8'))
        subprocess.run(['git','apply','--check',str(normalized)],cwd=source,check=True)
        subprocess.run(['git','apply',str(normalized)],cwd=source,check=True)
except Exception:
    for target, data in originals.items():
        target.write_bytes(data)
    raise
print('Applied Windows display-safety patch; upstream source and patch remain separately auditable.')
