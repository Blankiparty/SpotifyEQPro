#!/usr/bin/env python3
import argparse, hashlib, json, plistlib, struct, zipfile
from pathlib import Path

LOAD = '@executable_path/Frameworks/BlitzerAudioFix.dylib'
DEPENDENCIES = (0xc, 0x80000018, 0x8000001f, 0x20, 0x80000023)

def commands(data):
    if len(data) < 32 or struct.unpack_from('<I', data)[0] != 0xfeedfacf:
        raise ValueError('Expected thin little-endian 64-bit Mach-O')
    if struct.unpack_from('<I', data, 4)[0] != 0x100000c:
        raise ValueError('Expected arm64 Mach-O')
    count, length = struct.unpack_from('<II', data, 16)
    end, offset, result = 32 + length, 32, []
    for _ in range(count):
        kind, size = struct.unpack_from('<II', data, offset)
        if size < 8 or size % 8 or offset + size > end:
            raise ValueError('Invalid load command')
        result.append((kind, offset, size)); offset += size
    if offset != end: raise ValueError('Load command count/size mismatch')
    return result

def dylib_name(data, offset, size):
    start = struct.unpack_from('<I', data, offset + 8)[0]
    if start < 24 or start >= size: raise ValueError('Invalid dylib name offset')
    return data[offset+start:offset+size].split(b'\0',1)[0].decode()

def inspect_library(data):
    if struct.unpack_from('<I', data, 12)[0] != 6: raise ValueError('Not a dynamic library')
    install_name, dependencies = None, []
    for kind, offset, size in commands(data):
        if kind in DEPENDENCIES or kind == 0xd:
            name = dylib_name(data, offset, size)
            if kind == 0xd: install_name = name; continue
            dependencies.append(name)
            if not name.startswith(('/System/Library/Frameworks/', '/usr/lib/')):
                raise ValueError('Non-system dependency: ' + name)
            if any(x in name.lower() for x in ('substrate','substitute','libhooker','/var/jb')):
                raise ValueError('Jailbreak dependency: ' + name)
    if install_name != '@rpath/BlitzerAudioFix.dylib':
        raise ValueError('Unexpected install name: ' + str(install_name))
    return dependencies

def inject(data):
    parsed = commands(data)
    if struct.unpack_from('<I', data, 12)[0] != 2: raise ValueError('App is not MH_EXECUTE')
    end, first = 32 + struct.unpack_from('<I', data, 20)[0], len(data)
    for kind, offset, size in parsed:
        if kind in DEPENDENCIES and dylib_name(data, offset, size) == LOAD:
            raise ValueError('Fix is already injected')
        if kind == 0x2c and struct.unpack_from('<I', data, offset + 16)[0]:
            raise ValueError('Encrypted executable is unsupported')
        if kind == 0x19:
            for i in range(struct.unpack_from('<I', data, offset + 64)[0]):
                section = offset + 72 + i*80
                position = struct.unpack_from('<I', data, section + 48)[0]
                if position: first = min(first, position)
    name = LOAD.encode() + b'\0'; size = (24 + len(name) + 7) & ~7
    if end + size > first or any(data[end:end+size]):
        raise ValueError('No safe zero-filled Mach-O header padding')
    command = struct.pack('<IIIIII',0xc,size,24,0,0x10000,0x10000)+name
    output = bytearray(data); output[end:end+size] = command.ljust(size,b'\0')
    struct.pack_into('<II',output,16,len(parsed)+1,end-32+size)
    if output[end+size:] != data[end+size:]: raise AssertionError('Binary data shifted')
    return bytes(output)

def package(base, library, output):
    dylib = library.read_bytes(); dependencies = inspect_library(dylib)
    with zipfile.ZipFile(base) as source:
        names=source.namelist()
        if len(names)!=len(set(names)): raise ValueError('Duplicate ZIP entries')
        infos=[n for n in names if n.startswith('Payload/') and n.count('/')==2 and n.endswith('.app/Info.plist')]
        if len(infos)!=1: raise ValueError('Expected one app')
        plist=plistlib.loads(source.read(infos[0])); root=infos[0].rsplit('/',1)[0]
        executable=root+'/'+plist['CFBundleExecutable']; target=root+'/Frameworks/BlitzerAudioFix.dylib'
        if target in names: raise ValueError('Fix already embedded')
        patched=inject(source.read(executable))
        with zipfile.ZipFile(output,'w',zipfile.ZIP_DEFLATED,compresslevel=6) as dest:
            for entry in source.infolist(): dest.writestr(entry,patched if entry.filename==executable else source.read(entry.filename))
            entry=zipfile.ZipInfo(target);entry.create_system=3;entry.external_attr=0o100755<<16;entry.compress_type=zipfile.ZIP_DEFLATED
            dest.writestr(entry,dylib)
    with zipfile.ZipFile(output) as final, zipfile.ZipFile(base) as source:
        if final.testzip(): raise ValueError('Corrupt output archive')
        if set(final.namelist()) != set(source.namelist())|{target}: raise AssertionError('Archive contents changed')
        for name in source.namelist():
            if name!=executable and final.read(name)!=source.read(name): raise AssertionError('Changed entry: '+name)
        if final.read(target)!=dylib: raise AssertionError('Embedded library mismatch')
    return {'output':output.name,'sha256':hashlib.sha256(output.read_bytes()).hexdigest(),'bundle_id':plist['CFBundleIdentifier'],'version':plist.get('CFBundleShortVersionString'),'dependencies':dependencies}

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('base',type=Path);p.add_argument('library',type=Path);p.add_argument('output',type=Path);a=p.parse_args()
    print(json.dumps(package(a.base,a.library,a.output),indent=2))
