#!/usr/bin/env python3
"""Build only self-authored audio bytes and a libc-free ARM EABI installer tool.
No OEM input is read. Set ANDROID_NDK_HOME or pass --ndk. Output:
packages/audio-format/bin/audio-patch, .build/audio/formats.elf + recipe.h.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
ROOT=Path(__file__).resolve().parents[2]

def section(data,name):
 off=struct.unpack_from('<I',data,32)[0]
 size,count,strings=struct.unpack_from('<HHH',data,46)
 headers=[struct.unpack_from('<IIIIIIIIII',data,off+i*size) for i in range(count)]
 sh=headers[strings]; names=data[sh[4]:sh[4]+sh[5]]
 for h in headers:
  if names[h[0]:].split(b'\0',1)[0].decode()==name: return data[h[4]:h[4]+h[5]]
 raise ValueError('missing ELF section '+name)

def main():
 p=argparse.ArgumentParser();p.add_argument('--ndk',default=os.environ.get('ANDROID_NDK_HOME') or os.environ.get('NDK'));a=p.parse_args()
 if not a.ndk: p.error('set ANDROID_NDK_HOME or pass --ndk')
 host='windows-x86_64' if os.name=='nt' else 'linux-x86_64'
 tool=Path(a.ndk)/'toolchains/llvm/prebuilt'/host/'bin'
 clang=tool/('clang.exe' if os.name=='nt' else 'clang')
 out=ROOT/'.build/audio';out.mkdir(parents=True,exist_ok=True)
 def run(args):subprocess.run([str(clang),'--target=armv7a-linux-androideabi19',*map(str,args)],check=True,cwd=ROOT)
 run(['-nostdlib','-Wl,-T,tools/audio/layout.ld','-Wl,-e,input_formats','-Wl,--build-id=none','-Wl,-no-pie','tools/audio/formats.S','-o',out/'formats.elf'])
 for profile,suffix in [('recipe.json',''),('recipe-v035.json','-v035'),('recipe-v039gl3.json','-v039gl3')]:
  recipe=json.loads((ROOT/'tools/audio'/profile).read_text())
  include=out if not suffix else out/suffix[1:];include.mkdir(parents=True,exist_ok=True)
  header=['#define ORIGINAL_SHA "'+recipe['original_sha256']+'"','#define PATCHED_SHA "'+recipe['patched_sha256']+'"']
  for index,patch in enumerate(recipe['patches']):
   data=section((out/'formats.elf').read_bytes(),patch['section'])
   if len(data)!=patch['length'] or hashlib.sha256(data).hexdigest()!=patch['replacement_sha256']:raise SystemExit('replacement differs from reviewed recipe: '+patch['section'])
   header.append('static const unsigned char replacement%d[] = {%s};'%(index,','.join(map(str,data))))
  header.append('static const struct patch patches[] = {'+','.join('{%d,%d,replacement%d}'%(p['offset'],p['length'],i) for i,p in enumerate(recipe['patches']))+'};')
  (include/'recipe.h').write_text('\n'.join(header)+'\n',newline='\n')
  run(['-std=c99','-Os','-Wall','-Wextra','-Werror','-fno-builtin','-fno-stack-protector','-fno-unwind-tables','-fno-asynchronous-unwind-tables','-fno-pie','-nostdlib','-static','-Wl,-e,_start','-Wl,--build-id=none','-I',include,'tools/audio/patch.c','tools/audio/runtime.c','tools/audio/syscalls.S','-o',ROOT/'packages/audio-format/bin'/('audio-patch'+suffix)])
  env=['AUDIO_RECIPE='+recipe['id']]+['AUDIO_'+name.upper()+'_SHA='+value for name,value in recipe['dependencies'].items()]
  (ROOT/'packages/audio-format/scripts'/('recipe'+suffix+'.sh')).write_text('\n'.join(env)+'\n',newline='\n')
  print('Built freestanding ARM audio-patch'+suffix+'; two authored sections verified')
if __name__=='__main__':main()
