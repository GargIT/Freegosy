"""Regenerates the PS2 memory card fixtures used by ps2_memory_card_test.dart.

The cards are made with mymcplus (https://github.com/thestr4ng3r/mymcplus),
an independent implementation of the PS2 memory card file system, so the
tests check Freegosy's reader against someone else's writer. Needs
`pip install mymcplus==3.0.5`; run from this directory. The file contents
are synthetic (byte patterns), not real game data. Cards without ECC are
derived from these in the tests: mymcplus 3.0.5 writes a stray block past
the end of an image without ECC.
"""
import gzip
import os

from mymcplus import ps2mc

PARAMS = (True, ps2mc.PS2MC_STANDARD_PAGE_SIZE,
          ps2mc.PS2MC_STANDARD_PAGES_PER_ERASE_BLOCK,
          ps2mc.PS2MC_STANDARD_PAGES_PER_CARD)


def pattern(seed, length):
    return bytes((seed + i * 7) & 0xFF for i in range(length))


def write(mc, path, data):
    g = mc.open(path, 'wb')
    g.write(data)
    g.close()


def build(path, ecc, saves, deleted=()):
    params = (ecc,) + PARAMS[1:]
    with open(path, 'w+b') as f:
        mc = ps2mc.ps2mc(f, True, params)
        for name in deleted:
            mc.mkdir('/' + name)
            write(mc, f'/{name}/data', pattern(99, 5000))
        for name, files in saves:
            mc.mkdir('/' + name)
            for fname, data in files:
                write(mc, f'/{name}/{fname}', data)
        for name in deleted:
            mc.remove(f'/{name}/data')
            mc.remove('/' + name)
        mc.close()
    with open(path, 'rb') as f, open(path + '.gz', 'wb') as out:
        out.write(gzip.compress(f.read(), mtime=0))
    os.remove(path)


SAVES = [
    ('BASLUS-20502', [
        ('BASLUS-20502', pattern(1, 3000)),
        ('icon.sys', pattern(2, 964)),
        ('empty', b''),
    ]),
    # spans many clusters and more than one directory cluster of files
    ('BESCES-52438GAMEDATA', [
        ('BESCES-52438GAMEDATA', pattern(3, 150000)),
        ('icon.sys', pattern(4, 964)),
        ('view.ico', pattern(5, 33000)),
    ]),
    ('BASLUS-21026-PROFILE', [
        ('BASLUS-21026-PROFILE', pattern(6, 1024)),  # exactly one cluster
    ]),
]

build('formatted.ps2', True, [])
build('three_saves.ps2', True, SAVES, deleted=['BASLUS-99999'])
