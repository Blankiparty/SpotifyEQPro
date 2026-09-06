"""Expose only the built public-source library through the authenticated log API.
The uploaded Spotify base IPA is never sent to GitHub.
"""
import base64
import hashlib
import io
import sys
import textwrap
import zipfile
from pathlib import Path
root = Path(sys.argv[1])
archive = io.BytesIO()
with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_DEFLATED) as z:
    for name in ('SpotifyEQPro.dylib', 'dependencies.txt', 'commit.txt'):
        z.writestr(name, (root / name).read_bytes())
raw = archive.getvalue()
print('EQP_PORTABLE_SHA256=' + hashlib.sha256(raw).hexdigest())
print('EQP_PORTABLE_BEGIN')
print('\n'.join(textwrap.wrap(base64.b64encode(raw).decode(), 76)))
print('EQP_PORTABLE_END')
