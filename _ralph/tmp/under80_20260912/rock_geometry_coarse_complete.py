"""Validate four declared samples after the same fresh-process exit race."""
from pathlib import Path
source=Path(__file__).with_name('decor_rejection_coarse_complete.py').read_text()
source=source.replace('decor_rejection','rock_geometry').replace('decor_ms','annotation_ms')
source=source.replace("annotation_ms=audit['annotation_ms'],identity=audit['identity']",
 "annotation_ms=audit['annotation_ms'],capture_ms=audit['capture_ms'],identity=audit['identity']")
source=source.replace('driver23225','driver80524').replace('in12667','in45216')
exec(compile(source,str(Path(__file__)),'exec'))
