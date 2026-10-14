from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='linkdesk-recovery-tests-') as folder:
 work=Path(folder)
 model=(root/'macOS/LinkDesk.swift').read_text().split('class AppDelegate:')[0]
 (work/'RecoveryModel.swift').write_text(model)
 sources=['Configuration.swift','Identity.swift','Peers.swift','Discovery.swift','Lifecycle.swift']
 subprocess.run(['swiftc','-swift-version','5','-parse-as-library','-module-cache-path',str(work/'cache'),*[str(root/'macOS'/name) for name in sources],str(work/'RecoveryModel.swift'),str(root/'tests/RecoveryModelTests.swift'),'-o',str(work/'tests')],check=True)
 subprocess.run([str(work/'tests'),str(root/'tests/FakeMacCore.py')],check=True)
