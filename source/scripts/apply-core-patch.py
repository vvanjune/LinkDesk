"""Apply LinkDesk's auditable Windows display patch to pinned Deskflow 1.27.0."""
from pathlib import Path
import argparse,subprocess
p=argparse.ArgumentParser();p.add_argument('source',type=Path);args=p.parse_args()
patch=Path(__file__).resolve().parent.parent/'core-patches/windows-display-safety.patch'
subprocess.run(['git','apply','--check',str(patch)],cwd=args.source,check=True)
subprocess.run(['git','apply',str(patch)],cwd=args.source,check=True)
print('Applied Windows display-safety patch; upstream source and patch remain separately auditable.')
