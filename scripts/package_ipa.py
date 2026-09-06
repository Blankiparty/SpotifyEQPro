#!/usr/bin/env python3
"""Embed the exact built jailed library; output still requires sideload signing."""
import argparse
import hashlib
import json
import plistlib
import struct
import zipfile
from pathlib import Path

LOAD = '@executable_path/Frameworks/SpotifyEQPro.dylib'
DEPENDENCIES = (0xc, 0x80000018, 0x8000001f, 0x20, 0x80000023)

def commands(data):
    if len(data) < 32 or struct.unpack_from('<I', data)[0] != 0xfeedfacf:
        raise ValueError('Expected thin little-endian 64-bit Mach-O')
    if struct.unpack_from('<I', data, 4)[0] != 0x100000c:
        raise ValueError('Expected arm64 Mach-O')
    count, length = struct.unpack_from('<II', data, 16)
    end = 32 + length
    if end > len(data):
        raise ValueError('Load commands extend beyond file')
    result = []
    offset = 32
    for _ in range(count):
        if offset + 8 > end:
            raise ValueError('Truncated load command')
        kind, size = struct.unpack_from('<II', data, offset)
        if size < 8 or size % 8 or offset + size > end:
            raise ValueError('Invalid load command size')
        result.append((kind, offset, size))
        offset += size
    if offset != end:
        raise ValueError('Load command count/size mismatch')
    return result

def dylib_name(data, offset, size):
    start = struct.unpack_from('<I', data, offset + 8)[0]
    if start < 24 or start >= size:
        raise ValueError('Invalid dylib name offset')
    return data[offset+start:offset+size].split(b'\0', 1)[0].decode('utf-8')

def inspect_library(data):
    if struct.unpack_from('<I', data, 12)[0] != 6:
        raise ValueError('Input is not a dynamic library')
    dependencies = []
    install_name = None
    for kind, offset, size in commands(data):
        if kind in DEPENDENCIES or kind == 0xd:
            name = dylib_name(data, offset, size)
            if kind == 0xd:
                install_name = name
                continue
            dependencies.append(name)
            if not name.startswith(('/System/Library/Frameworks/', '/usr/lib/')):
                raise ValueError(f'Non-system dependency in SpotifyEQPro: {name}')
            if any(x in name.lower() for x in ('substrate', 'substitute', 'libhooker', '/var/jb')):
                raise ValueError(f'Jailbreak dependency: {name}')
    if install_name != '@rpath/SpotifyEQPro.dylib':
        raise ValueError(f'Unexpected library install name: {install_name}')
    return dependencies

def inject(data):
    parsed = commands(data)
    if struct.unpack_from('<I', data, 12)[0] != 2:
        raise ValueError('App binary is not MH_EXECUTE')
    end = 32 + struct.unpack_from('<I', data, 20)[0]
    first = len(data)
    for kind, offset, size in parsed:
        if kind in DEPENDENCIES:
            name = dylib_name(data, offset, size)
            if 'SpotifyEQPro' in name or 'SpotifyEQ10' in name:
                raise ValueError('Base IPA already contains an EQ injection; use the original base IPA')
        if kind == 0x2c and struct.unpack_from('<I', data, offset + 16)[0]:
            raise ValueError('Encrypted app executable is not supported')
        if kind == 0x19:
            count = struct.unpack_from('<I', data, offset + 64)[0]
            if 72 + count * 80 > size:
                raise ValueError('Invalid segment sections')
            for i in range(count):
                section = offset + 72 + i * 80
                position = struct.unpack_from('<I', data, section + 48)[0]
                if position:
                    first = min(first, position)
    name = LOAD.encode() + b'\0'
    size = (24 + len(name) + 7) & ~7
    if end + size > first or any(data[end:end + size]):
        raise ValueError('No safe zero-filled header padding; refusing to shift binary data')
    command = struct.pack('<IIIIII', 0xc, size, 24, 0, 0x10000, 0x10000) + name
    command = command.ljust(size, b'\0')
    output = bytearray(data)
    output[end:end + size] = command
    struct.pack_into('<II', output, 16, len(parsed) + 1, end - 32 + size)
    assert len(output) == len(data)
    assert output[end + size:] == data[end + size:]
    check = [dylib_name(output, offset, n) for kind, offset, n in commands(output) if kind in DEPENDENCIES]
    assert check.count(LOAD) == 1
    return bytes(output)

def package(base, library, output):
    if output.resolve() in (base.resolve(), library.resolve()):
        raise ValueError('Output must not overwrite an input')
    dylib = library.read_bytes()
    dependencies = inspect_library(dylib)
    with zipfile.ZipFile(base) as source:
        names = source.namelist()
        if len(names) != len(set(names)):
            raise ValueError('Base contains duplicate ZIP entries')
        infos = [n for n in names if n.startswith('Payload/') and n.count('/') == 2 and n.endswith('.app/Info.plist')]
        if len(infos) != 1:
            raise ValueError('Expected exactly one top-level app')
        info = plistlib.loads(source.read(infos[0]))
        root = infos[0].rsplit('/', 1)[0]
        executable = root + '/' + info['CFBundleExecutable']
        target = root + '/Frameworks/SpotifyEQPro.dylib'
        if target in names:
            raise ValueError('Base already contains SpotifyEQPro')
        binary = inject(source.read(executable))
        output.parent.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(output, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=6) as dest:
            for entry in source.infolist():
                dest.writestr(entry, binary if entry.filename == executable else source.read(entry.filename))
            entry = zipfile.ZipInfo(target)
            entry.create_system = 3
            entry.external_attr = 0o100755 << 16
            entry.compress_type = zipfile.ZIP_DEFLATED
            dest.writestr(entry, dylib)
    # Verify the deliverable and byte-for-byte preservation of every other entry.
    with zipfile.ZipFile(output) as final, zipfile.ZipFile(base) as source:
        assert final.testzip() is None
        assert set(final.namelist()) == set(source.namelist()) | {target}
        for name in source.namelist():
            if name != executable:
                assert final.read(name) == source.read(name), name
        assert final.read(target) == dylib
    return {
        'output': output.name,
        'ipa_sha256': hashlib.sha256(output.read_bytes()).hexdigest(),
        'base_sha256': hashlib.sha256(base.read_bytes()).hexdigest(),
        'dylib_sha256': hashlib.sha256(dylib).hexdigest(),
        'bundle_id': info['CFBundleIdentifier'],
        'base_version': info.get('CFBundleShortVersionString'),
        'dependencies': dependencies,
        'signing': 'Re-sign with your normal sideloading tool before installing on a jailed device',
        'preserved': 'Every base archive entry except the main executable is byte-identical',
    }

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('base', type=Path)
    parser.add_argument('library', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    print(json.dumps(package(args.base, args.library, args.output), indent=2))
