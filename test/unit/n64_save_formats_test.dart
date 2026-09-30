import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:freegosy/core/save/formats/n64_save_formats.dart';
import 'package:freegosy/core/save/formats/save_format.dart';

/// N64 saves, from mupen64plus-libretro-nx (libretro/libretro_memory.h,
/// mupen64plus-core device/cart/*.c, device/controllers/paks/mempak.c) and
/// ares (ares/n64/cartridge/cartridge.cpp, ares/n64/memory/msb/writable.hpp).
void main() {
  const mupen = N64MupenSrmFormat();
  const ares = N64AresFormat();

  /// Bytes 0, 1, 2, ... (mod 251) — any wrong offset or missed swap shows.
  Uint8List pattern(int size, [int seed = 0]) =>
      Uint8List.fromList(List.generate(size, (i) => (i + seed) % 251));

  Uint8List blankSrm() => Uint8List(N64Layout.srmSize)..fillRange(0, N64Layout.srmSize, 0xFF);

  test('the layout adds up to Mupen64Plus\' 0x48800 bytes', () {
    expect(N64Layout.paksOffset, 0x800);
    expect(N64Layout.sramOffset, 0x20800);
    expect(N64Layout.flashOffset, 0x28800);
    expect(N64Layout.srmSize, 0x48800);
  });

  test('swapWords reverses each 32-bit word, and twice is the original', () {
    expect(swapWords(Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8])), [4, 3, 2, 1, 8, 7, 6, 5]);
    final data = pattern(64);
    expect(swapWords(swapWords(data)), data);
  });

  group('formattedMempak (format_mempak)', () {
    final pak = formattedMempak();
    int be16(int at) => (pak[at] << 8) | pak[at + 1];

    test('is one 32 KB pak', () => expect(pak.length, 0x8000));

    test('the ID block and its three backups carry a valid checksum', () {
      var sum = 0;
      for (var i = 32; i < 32 + 28; i += 2) {
        sum = (sum + be16(i)) & 0xFFFF;
      }
      expect(be16(32 + 28), sum);
      expect(be16(32 + 30), (0xFFF2 - sum) & 0xFFFF);
      expect(be16(32 + 24), 0x0001, reason: 'device id');
      expect(pak[32 + 26], 0x01, reason: 'banks');
      for (final backup in [3, 4, 6]) {
        expect(pak.sublist(backup * 32, backup * 32 + 32), pak.sublist(32, 64), reason: 'block $backup');
      }
      for (final zero in [0, 2, 5, 7]) {
        expect(pak.sublist(zero * 32, zero * 32 + 32).every((b) => b == 0), isTrue, reason: 'block $zero');
      }
    });

    test('the index table marks all 123 pages free, with its checksum and backup', () {
      for (var i = 5; i < 128; i++) {
        expect(be16(256 + 2 * i), 0x0003, reason: 'page $i');
      }
      expect(pak[256 + 1], (123 * 3) & 0xFF);
      expect(pak.sublist(512, 768), pak.sublist(256, 512));
    });

    test('everything after the index tables is zero', () {
      expect(pak.sublist(768).every((b) => b == 0), isTrue);
    });
  });

  group('Mupen64Plus-Next / ParaLLEl .srm', () {
    test('decodes each part at its offset, SRAM and FlashRAM word-swapped', () {
      final srm = blankSrm();
      final eeprom = pattern(0x800, 1);
      final sramNatural = pattern(0x8000, 2);
      final flashNatural = pattern(0x20000, 3);
      srm.setRange(0, 0x800, eeprom);
      srm.setRange(N64Layout.sramOffset, N64Layout.sramOffset + 0x8000, swapWords(sramNatural));
      srm.setRange(N64Layout.flashOffset, N64Layout.flashOffset + 0x20000, swapWords(flashNatural));
      final pak0 = pattern(0x8000, 4);
      srm.setRange(0x800, 0x800 + 0x8000, pak0);

      final save = mupen.decode([SaveBlob('Game.srm', srm)]);

      expect(save.eeprom, eeprom);
      expect(save.sram, sramNatural);
      expect(save.flash, flashNatural);
      expect(save.paks!.length, 4);
      expect(save.paks![0], pak0, reason: 'controller paks are byte-addressed: not swapped');
    });

    test('parts the game never wrote (all 0xFF) are absent', () {
      final srm = blankSrm()..setRange(0, 4, [1, 2, 3, 4]);
      final save = mupen.decode([SaveBlob('Game.srm', srm)]);
      expect(save.eeprom, isNotNull);
      expect(save.sram, isNull);
      expect(save.flash, isNull);
    });

    test('a ParaLLEl .srm with a 64DD disk area decodes, the disk area ignored', () {
      final srm = Uint8List(N64Layout.srmSize + 4096)..fillRange(0, N64Layout.srmSize, 0xFF);
      srm.setRange(0, 4, [9, 8, 7, 6]);
      expect(mupen.recognises([SaveBlob('Game.srm', srm)]), isTrue);
      expect(mupen.decode([SaveBlob('Game.srm', srm)]).eeprom!.sublist(0, 4), [9, 8, 7, 6]);
    });

    test('recognises only a big enough .srm, whatever the case of its extension', () {
      expect(mupen.recognises([SaveBlob('Game.SRM', blankSrm())]), isTrue);
      expect(mupen.recognises([SaveBlob('Game.srm', Uint8List(0x20000))]), isFalse, reason: 'a PS1 card');
      expect(mupen.recognises([SaveBlob('Game.eeprom', blankSrm())]), isFalse);
    });

    test('encode fills what the core would: 0xFF, and four formatted paks when the source has none', () {
      final out = mupen.encode(N64SaveData(eeprom: pattern(512, 5)), stem: 'Game (USA)');
      expect(out.single.name, 'Game (USA).srm');
      final srm = out.single.bytes;
      expect(srm.length, N64Layout.srmSize);
      expect(srm.sublist(0, 512), pattern(512, 5));
      expect(srm.sublist(512, 0x800).every((b) => b == 0xFF), isTrue);
      for (var i = 0; i < 4; i++) {
        final at = N64Layout.paksOffset + i * 0x8000;
        expect(srm.sublist(at, at + 0x8000), formattedMempak(), reason: 'pak $i');
      }
      expect(srm.sublist(N64Layout.sramOffset).every((b) => b == 0xFF), isTrue);
    });

    test('decode then encode gives the same file', () {
      final srm = blankSrm()
        ..setRange(0, 0x800, pattern(0x800, 6))
        ..setRange(0x800, 0x20800, pattern(0x20000, 7))
        ..setRange(N64Layout.sramOffset, N64Layout.flashOffset, pattern(0x8000, 8));
      final again = mupen.encode(mupen.decode([SaveBlob('G.srm', srm)]), stem: 'G').single.bytes;
      expect(again, srm);
    });
  });

  group('ares', () {
    test('keeps EEPROM, SRAM and FlashRAM in the N64\'s own byte order, one file each', () {
      final save = N64SaveData(eeprom: pattern(0x800, 1), sram: pattern(0x8000, 2), flash: pattern(0x20000, 3));
      final out = ares.encode(save, stem: 'game (usa)');
      expect(out.map((f) => f.name), ['game (usa).eeprom', 'game (usa).ram', 'game (usa).flash']);
      expect(out[1].bytes, pattern(0x8000, 2));
      expect(out[2].bytes, pattern(0x20000, 3));
    });

    test('writes only the parts the game uses', () {
      expect(ares.encode(N64SaveData(sram: pattern(0x8000)), stem: 'g').map((f) => f.name), ['g.ram']);
      expect(ares.encode(const N64SaveData(), stem: 'g'), isEmpty);
    });

    test('a 4 Kbit EEPROM is written at its own 512 bytes, a 16 Kbit one at 2048', () {
      final small = Uint8List(0x800)..fillRange(0, 0x800, 0xFF)..setRange(0, 512, pattern(512));
      expect(ares.encode(N64SaveData(eeprom: small), stem: 'g').single.bytes.length, 512);
      expect(ares.encode(N64SaveData(eeprom: pattern(0x800)), stem: 'g').single.bytes.length, 0x800);
    });

    test('decodes its files, a short EEPROM padded to 0x800 with 0xFF, and keeps no paks', () {
      final save = ares.decode([SaveBlob('g.eeprom', pattern(512)), SaveBlob('g.RAM', pattern(0x8000, 1))]);
      expect(save.eeprom!.length, 0x800);
      expect(save.eeprom!.sublist(0, 512), pattern(512));
      expect(save.eeprom!.sublist(512).every((b) => b == 0xFF), isTrue);
      expect(save.sram, pattern(0x8000, 1));
      expect(save.paks, isNull);
    });

    test('recognises only its own extensions, each at most once', () {
      expect(ares.recognises([SaveBlob('g.eeprom', Uint8List(512))]), isTrue);
      expect(ares.recognises([SaveBlob('g.EEPROM', Uint8List(512)), SaveBlob('g.flash', Uint8List(16))]), isTrue);
      expect(ares.recognises([SaveBlob('g.srm', Uint8List(512))]), isFalse);
      expect(ares.recognises([SaveBlob('g.ram', Uint8List(8)), SaveBlob('h.ram', Uint8List(8))]), isFalse);
      expect(ares.recognises([]), isFalse);
    });

    test('an SRAM bigger than Mupen64Plus keeps (e.g. Dezaemon 3D\'s 128 KB) is refused', () {
      expect(() => ares.decode([SaveBlob('g.ram', Uint8List(0x20000))]), throwsFormatException);
    });
  });

  test('ares → .srm → ares gives the same files', () {
    final files = [SaveBlob('g.eeprom', pattern(512, 9))];
    final srm = mupen.encode(ares.decode(files), stem: 'g');
    final back = ares.encode(mupen.decode(srm), stem: 'g');
    expect(back.map((f) => f.name), ['g.eeprom']);
    expect(back.single.bytes, pattern(512, 9));
  });
}
