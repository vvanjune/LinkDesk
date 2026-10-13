from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix="linkdesk-recovery-tests-") as folder:
    work = Path(folder)
    model = (root / "macOS/LinkDesk.swift").read_text().split("class AppDelegate:")[0]
    model = model.replace("UserDefaults.standard", "recoveryDefaults").replace('Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/deskflow-core")', 'URL(fileURLWithPath: "/tmp/linkdesk-test-no-core")')
    model = model.replace('FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/LinkDesk")', 'URL(fileURLWithPath: "' + str(work / "profile") + '")').replace('Library/Deskflow/tls', 'linkdesk-test-no-legacy')
    (work / "RecoveryModel.swift").write_text(model)
    subprocess.run(["swiftc", "-swift-version", "5", "-parse-as-library", "-module-cache-path", str(work / "cache"), str(root / "macOS/Configuration.swift"), str(root / "macOS/Identity.swift"), str(root / "macOS/Peers.swift"), str(root / "macOS/Discovery.swift"), str(work / "RecoveryModel.swift"), str(root / "tests/RecoveryModelTests.swift"), "-o", str(work / "tests")], check=True)
    subprocess.run([str(work / "tests")], check=True)
