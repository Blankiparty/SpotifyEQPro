import base64, hashlib, io, sys, textwrap, zipfile
from pathlib import Path
root=Path(sys.argv[1]);archive=io.BytesIO()
with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED) as z:
    for name in ('BlitzerAudioFix.dylib','dependencies.txt','commit.txt'):
        z.writestr(name,(root/name).read_bytes())
raw=archive.getvalue()
print('BAF_PORTABLE_SHA256='+hashlib.sha256(raw).hexdigest())
print('BAF_PORTABLE_BEGIN')
print('\n'.join(textwrap.wrap(base64.b64encode(raw).decode(),76)))
print('BAF_PORTABLE_END')
