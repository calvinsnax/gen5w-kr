"""Compile authored ODEX recipes with the project's freestanding patch engine."""
import argparse
import json
import os
from pathlib import Path
import subprocess

ROOT=Path(__file__).resolve().parents[2]
def main():
    p=argparse.ArgumentParser();p.add_argument('--ndk',default=os.environ.get('ANDROID_NDK_HOME'));a=p.parse_args()
    if not a.ndk: p.error('--ndk or ANDROID_NDK_HOME required')
    host='windows-x86_64' if os.name=='nt' else 'linux-x86_64'
    clang=Path(a.ndk)/'toolchains/llvm/prebuilt'/host/'bin'/('clang.exe' if os.name=='nt' else 'clang')
    dest=ROOT/'packages/wireless-bridge/bin';dest.mkdir(parents=True,exist_ok=True)
    targets = [(kind, version) for version in ('v035', 'v039', 'v039gl3')
               for kind in ('iap2', 'iap2-route', 'dipo', 'gpm')]
    for kind, version in targets:
        if kind == 'iap2': filename = f'{version}.json'
        elif kind == 'iap2-route': filename = f'route-{version}.json'
        elif kind == 'dipo': filename = f'dipo-{version}.json'
        elif kind == 'gpm': filename = f'gpm-{version}.json'
        r=json.loads((ROOT/'tools/iap2'/filename).read_text())
        out=ROOT/'.build/iap2'/kind/version;out.mkdir(parents=True,exist_ok=True)
        header=[f'#define ORIGINAL_SHA "{r["original_sha256"]}"',f'#define PATCHED_SHA "{r["patched_sha256"]}"']
        for i,patch in enumerate(r['patches']):
            header.append('static const unsigned char replacement%d[]={%s};'%(i,','.join(map(str,patch['bytes']))))
        header.append('static const struct patch patches[]={'+','.join('{%d,%d,replacement%d}'%(patch['offset'],len(patch['bytes']),i) for i,patch in enumerate(r['patches']))+'};')
        (out/'recipe.h').write_text('\n'.join(header)+'\n',newline='\n')
        subprocess.run([str(clang),'--target=armv7a-linux-androideabi19','-std=c99','-Os','-Wall','-Wextra','-Werror',
            '-fno-builtin','-fno-stack-protector','-fno-unwind-tables','-fno-asynchronous-unwind-tables',
            '-fno-pie','-nostdlib','-static','-Wl,-e,_start','-Wl,--build-id=none','-I',str(out),
            'tools/audio/patch.c','tools/audio/runtime.c','tools/audio/syscalls.S','-o',str(dest/f'{kind}-patch-{version}')],cwd=ROOT,check=True)
    print('Built freestanding ARM control-shim helpers')
if __name__=='__main__': main()
