"""Record actual nested signatures and core bytes before the final outer signature."""
from pathlib import Path
import hashlib,json,sys
app=Path(sys.argv[1]);contents=app/'Contents'
metadata_path=contents/'MacOS/linkdesk-core.json'
metadata=json.loads(metadata_path.read_text());metadata['sha256']=hashlib.sha256((contents/'MacOS/deskflow-core').read_bytes()).hexdigest();metadata_path.write_text(json.dumps(metadata,indent=2)+'\n')
manifest={}
for path in sorted(contents.rglob('*')):
 if not path.is_file() or path.is_symlink():continue
 relative=path.relative_to(contents)
 if relative.parts[0] not in {'Frameworks','PlugIns','Libraries'} and relative.as_posix() not in {'MacOS/deskflow-core','MacOS/linkdesk-core.json'}:continue
 manifest[relative.as_posix()]=hashlib.sha256(path.read_bytes()).hexdigest()
(contents/'Resources/ThirdParty/runtime-files.json').write_text(json.dumps(manifest,indent=2)+'\n')
print('Finalized Mac core and runtime integrity after nested signing')
