"""Bundle unmodified official Deskflow runtime files; never copy user TLS data."""
from pathlib import Path
import argparse, hashlib, json, shutil

parser = argparse.ArgumentParser()
parser.add_argument("platform", choices=["mac", "windows"])
parser.add_argument("upstream", type=Path)
parser.add_argument("output", type=Path)
args = parser.parse_args()
root = args.upstream.resolve()
out = args.output.resolve()
licenses = Path(__file__).resolve().parent.parent / "third-party"
if not licenses.is_dir():
    raise SystemExit("Missing source/third-party license notices")

if args.platform == "mac":
    root = root / "Contents"
    core = root / "MacOS/deskflow-core"
    if not core.is_file():
        raise SystemExit("Select the official Deskflow.app bundle to prepare this build")
    destination = out / "Contents"
    (destination / "MacOS").mkdir(parents=True, exist_ok=True)
    shutil.copy2(core, destination / "MacOS/deskflow-core")
    for name in ["Frameworks", "PlugIns", "Libraries"]:
        if (root / name).exists():
            if (destination / name).exists():
                shutil.rmtree(destination / name)
            shutil.copytree(root / name, destination / name, symlinks=True)
    resources = destination / "Resources"
    resources.mkdir(parents=True, exist_ok=True)
    shutil.copy2(root / "Resources/qt.conf", resources / "qt.conf")
    notices = resources / "ThirdParty"
    runtime = destination
else:
    if not (root / "deskflow-core.exe").is_file():
        raise SystemExit("Select the extracted official Deskflow Windows x64 portable folder")
    runtime = out / "core"
    if runtime.exists():
        shutil.rmtree(runtime)
    runtime.mkdir(parents=True)
    for path in [root / "deskflow-core.exe", *root.glob("*.dll")]:
        shutil.copy2(path, runtime / path.name)
    shutil.copytree(root / "plugins", runtime / "plugins")
    # This marker selects per-profile TLS paths instead of ProgramData/Deskflow.
    # Actual settings are always passed explicitly using --settings.
    (runtime / "settings").mkdir()
    (runtime / "settings/Deskflow.conf").write_text("; LinkDesk portable core marker; actual settings are in the user profile.\n")
    (runtime / "qt.conf").write_text("[Paths]\nPlugins=plugins\n")
    for required in ["Qt6Core.dll", "Qt6Gui.dll", "Qt6Network.dll", "Qt6Widgets.dll", "libssl-3-x64.dll", "libcrypto-3-x64.dll", "vcruntime140.dll", "vcruntime140_1.dll", "msvcp140.dll", "plugins/platforms/qwindows.dll"]:
        if not (runtime / required).is_file():
            raise SystemExit(f"Incomplete upstream runtime: {required}")
    notices = out / "ThirdParty"

if notices.exists():
    shutil.rmtree(notices)
shutil.copytree(licenses, notices)
manifest = {}
for path in sorted(runtime.rglob("*")):
    if not path.is_file() or path.is_symlink() or "ThirdParty" in path.parts:
        continue
    if path.name.endswith((".pem", ".key", ".p12", ".pfx")):
        raise SystemExit(f"Unexpected identity file: {path}")
    if args.platform == "mac" and path.relative_to(runtime).parts[0] not in {"Frameworks", "PlugIns", "Libraries"} and path.name != "deskflow-core":
        continue
    manifest[path.relative_to(runtime).as_posix()] = hashlib.sha256(path.read_bytes()).hexdigest()
(notices / "runtime-files.json").write_text(json.dumps(manifest, indent=2) + "\n")
print(f"Bundled {len(manifest)} runtime files into {out}")
