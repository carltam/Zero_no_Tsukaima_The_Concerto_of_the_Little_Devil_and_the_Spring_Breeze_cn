# -*- coding: utf-8 -*-
"""Patch music-mode song titles in the PS2 ELF with Chinese translations.

Reads translations/elf_songs.tsv (idx, jp, zh), encodes zh via the build's
encoding_map.txt + native_reuse.txt (2-byte game codes), writes each title
into its 0x80-byte slot at 0x116068 + idx*0x80 of the pristine ELF.
Output: <BuildDir>/SLPS_257.09.bin (same size, in-place slot rewrite).
"""
import argparse
import io
import os
import sys

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')

BASE = 0x116068
SLOT = 0x80


def load_map(path):
    m = {}
    for ln in open(path, encoding='utf-8-sig'):
        p = ln.rstrip('\n').split('\t')
        if len(p) == 2 and len(p[1]) == 4:
            m[p[0]] = int(p[1], 16)
    return m


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--elf', required=True, help='pristine ELF (work/SLPS_257.09.bin)')
    ap.add_argument('--tsv', default=None, help='elf_songs.tsv (idx, jp, zh)，由 build_all.ps1 传入')
    ap.add_argument('--build-dir', required=True)
    a = ap.parse_args()
    if not a.tsv:
        print('FAIL: --tsv is required')
        return 2

    codes = load_map(os.path.join(a.build_dir, 'encoding_map.txt'))
    codes.update(load_map(os.path.join(a.build_dir, 'native_reuse.txt')))

    data = bytearray(open(a.elf, 'rb').read())
    titles = []
    for ln in open(a.tsv, encoding='utf-8-sig'):
        p = ln.rstrip('\n').split('\t')
        if len(p) == 3:
            titles.append((int(p[0]), p[1], p[2]))

    patched = 0
    for idx, jp, zh in titles:
        off = BASE + idx * SLOT
        cur = data[off:off + SLOT]
        cur_s = cur.split(b'\x00')[0].decode('shift-jis', errors='replace')
        if cur_s != jp:
            print(f'FAIL slot {idx}: ELF has "{cur_s}" != tsv "{jp}"')
            return 1
        out = bytearray()
        for ch in zh:
            if ord(ch) < 0x80:
                out.append(ord(ch))
            elif ch in codes:
                v = codes[ch]
                out += bytes([v >> 8, v & 0xFF])
            else:
                print(f'FAIL slot {idx}: char {ch} not in encoding map')
                return 1
        if len(out) > SLOT - 1:
            print(f'FAIL slot {idx}: {len(out)} bytes > {SLOT - 1}')
            return 1
        data[off:off + SLOT] = bytes(out) + b'\x00' * (SLOT - len(out))
        patched += 1
        print(f'  [{idx:2d}] {jp} -> {zh} ({len(out)} bytes)')

    open(os.path.join(a.build_dir, 'SLPS_257.09.bin'), 'wb').write(bytes(data))
    print(f'patched {patched}/{len(titles)} titles -> {a.build_dir}\\SLPS_257.09.bin')
    return 0


if __name__ == '__main__':
    sys.exit(main())
