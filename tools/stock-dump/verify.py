#!/usr/bin/env python3
"""Verify a GEN5W-STOCK folder copied by tools/stock-dump/NEMESIS.sh (PC side).

Run with the folder as an argument, never from inside it:

    python3 -I tools/stock-dump/verify.py /Volumes/USB/GEN5W-STOCK [--check CHECK.txt]

It only reads the folder. For every copied file it recomputes MD5 (must match
the on-unit MD5 in MANIFEST.txt) and SHA-256, and classifies the SHA-256
against the hashes this repository already knows (registered stock/patched
V039/V035 of the reference vehicle). With --check it also confirms the files
are the same ones the pre-install check hashed. Prints a Markdown summary with
hashes and build facts only, safe to paste into a support request; the files
themselves must stay private.
"""
import argparse
import hashlib
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
# Targets the pre-install check verifies (CHECK.txt md5:<path> keys).
CHECK_TARGETS = [
    'framework/services.odex', 'priv-app/SystemUI.odex', 'lib/libCarPlayAudio.so',
    'app/Iap2ServerApp.odex', 'app/HKMC_DiPO.odex', 'app/HKMC_GPM.odex',
]
RECIPES = {
    'app/Iap2ServerApp.odex': ['tools/iap2/route-v039.json', 'tools/iap2/v039.json',
                               'tools/iap2/route-v035.json', 'tools/iap2/v035.json'],
    'app/HKMC_DiPO.odex': ['tools/iap2/dipo-v039.json', 'tools/iap2/dipo-v035.json'],
    'app/HKMC_GPM.odex': ['tools/iap2/gpm-v039.json', 'tools/iap2/gpm-v035.json'],
    'lib/libCarPlayAudio.so': ['tools/audio/recipe.json', 'tools/audio/recipe-v035.json'],
}


def known_hashes():
    """{rel: {sha256: label}} from the recipes and the check's boot-critical hashes."""
    known = {}
    for rel, files in RECIPES.items():
        for name in files:
            path = ROOT / name
            if not path.is_file():
                continue
            data = json.loads(path.read_text())
            version = 'v035' if 'v035' in name else 'v039'
            known.setdefault(rel, {})
            if data.get('original_sha256'):
                known[rel][data['original_sha256']] = f'stock-{version} (기준 차량)'
            if data.get('patched_sha256'):
                known[rel][data['patched_sha256']] = f'patched-{version} ({pathlib.Path(name).name})'
    check = (ROOT / 'tools/integrated/check.sh').read_text()
    for rel in ('framework/services.odex', 'priv-app/SystemUI.odex'):
        m = re.search(r'verify_hash ' + re.escape(rel) + r' ([0-9a-f]{64}) ([0-9a-f]{64})', check)
        if m:
            known.setdefault(rel, {})[m.group(1)] = 'stock-v039 (기준 차량)'
            known[rel][m.group(2)] = 'stock-v035 (기준 차량)'
    return known


def digests(path):
    md5, sha = hashlib.md5(), hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda: f.read(1 << 20), b''):
            md5.update(block)
            sha.update(block)
    return md5.hexdigest(), sha.hexdigest()


def read_manifest(path):
    facts, entries = {}, []
    for line in path.read_text(errors='replace').splitlines():
        parts = line.split(' ')
        if len(parts) == 3 and parts[0] in ('ok', 'missing', 'copy-failed'):
            entries.append(tuple(parts))
        elif '=' in line:
            key, _, value = line.partition('=')
            facts[key] = value
    return facts, entries


def read_check(path):
    out = {}
    for line in path.read_text(errors='replace').splitlines():
        if line.startswith('md5:') and '=' in line:
            key, _, value = line[4:].partition('=')
            out[key] = value.strip()
    return out


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument('folder', type=pathlib.Path, help='GEN5W-STOCK folder from the USB')
    p.add_argument('--check', type=pathlib.Path, help='GEN5W-REPORT/CHECK.txt from the same unit')
    p.add_argument('--sums', type=pathlib.Path, help='write SHA256SUMS here (outside the folder)')
    a = p.parse_args(argv)

    manifest = a.folder / 'MANIFEST.txt'
    if not manifest.is_file():
        print(f'ERROR {manifest} not found', file=sys.stderr)
        return 2
    facts, entries = read_manifest(manifest)
    known = known_hashes()
    check = read_check(a.check) if a.check else {}
    errors, rows, sums = [], [], []
    base = (a.folder / 'system').resolve()

    for status, md5_unit, rel in entries:
        if status != 'ok':
            rows.append((rel.removeprefix('system/'), status, '-', '-'))
            if status == 'copy-failed':
                errors.append(f'{rel}: 차량에서 복사 실패')
            continue
        path = (a.folder / rel).resolve()
        if base not in path.parents or not path.is_file() or path.is_symlink():
            errors.append(f'{rel}: 파일이 없거나 폴더 밖을 가리킵니다')
            continue
        md5, sha = digests(path)
        short = rel.removeprefix('system/')
        if md5 != md5_unit:
            errors.append(f'{short}: MD5 불일치 (차량 {md5_unit}, PC {md5}) — 복사 중 손상')
        label = known.get(short, {}).get(sha)
        if label is None:
            label = '미등록' if short in known else '-'
        if short in check and check[short] != md5:
            errors.append(f'{short}: CHECK.txt의 MD5({check[short]})와 다릅니다 — 점검 이후 파일이 바뀌었거나 다른 차량')
        rows.append((short, label, md5, sha))
        sums.append(f'{sha}  {short}')

    if a.check:
        for rel in CHECK_TARGETS:
            if rel in check and not any(r[0] == rel and r[2] != '-' for r in rows):
                errors.append(f'{rel}: CHECK.txt에는 있지만 수집본에 없습니다')

    if a.sums:
        a.sums.write_text('\n'.join(sums) + '\n')

    print('# Gen5W KR 순정 원본 수집 검증')
    print()
    for key in ('firmware', 'display_id', 'incremental', 'targetdir', 'hardware', 'android',
                'gen5w_backup', 'nemesis_apps', 'result', 'copied', 'copy_failed', 'missing'):
        print(f'- {key}: `{facts.get(key, "")}`')
    print()
    print('| 파일 | 분류 | MD5 | SHA-256 |')
    print('|---|---|---|---|')
    for short, label, md5, sha in rows:
        if short in known or short in CHECK_TARGETS or label in ('missing', 'copy-failed'):
            print(f'| `{short}` | {label} | `{md5}` | `{sha}` |')
    print()
    print(f'전체 {len(sums)}개 파일의 SHA-256은 --sums 파일에 있습니다. 위 표는 패치 대상만 보여 줍니다.')
    if facts.get('gen5w_backup') == 'present':
        errors.append('차량에 gen5w-kr 백업 폴더가 있습니다. 수집본이 순정이 아닐 수 있습니다')
    if errors:
        print()
        print('## 문제')
        for e in errors:
            print(f'- {e}')
        return 1
    print()
    print('수집본이 차량의 MD5와 일치합니다. 파일 자체는 공개 이슈에 올리지 마세요.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
