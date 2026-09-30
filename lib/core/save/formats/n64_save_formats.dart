import 'dart:typed_data';

import 'save_format.dart';

/// An N64 game's save in the N64's own (big-endian) byte order. A cartridge
/// part is null when the game doesn't use it; [paks] holds the four
/// controller pak slots, or is null when the source keeps no paks (ares).
class N64SaveData {
  const N64SaveData({this.eeprom, this.sram, this.flash, this.paks});

  final Uint8List? eeprom;
  final Uint8List? sram;
  final Uint8List? flash;
  final List<Uint8List>? paks;
}

/// Mupen64Plus-Next's and ParaLLEl N64's save RAM, the one `.srm` RetroArch
/// writes (`save_memory_data` in libretro/libretro_memory.h). ParaLLEl
/// appends a 64DD disk area after it for 64DD games only.
class N64Layout {
  N64Layout._();

  static const eepromSize = 0x800;
  static const pakSize = 0x8000;
  static const sramSize = 0x8000;
  static const flashSize = 0x20000;

  static const paksOffset = eepromSize;
  static const sramOffset = paksOffset + 4 * pakSize;
  static const flashOffset = sramOffset + sramSize;
  static const srmSize = flashOffset + flashSize;
}

/// [bytes] with the bytes of every 32-bit word reversed. Mupen64Plus keeps
/// SRAM and FlashRAM as host-order words (`mem[addr ^ S8]`, little-endian on
/// PCs); the N64 and ares keep them big-endian.
Uint8List swapWords(Uint8List bytes) {
  final out = Uint8List(bytes.length);
  for (var i = 0; i + 3 < bytes.length; i += 4) {
    out[i] = bytes[i + 3];
    out[i + 1] = bytes[i + 2];
    out[i + 2] = bytes[i + 1];
    out[i + 3] = bytes[i];
  }
  return out;
}

/// An empty controller pak as Mupen64Plus formats one (`format_mempak` in
/// mupen64plus-core device/controllers/paks/mempak.c: device id 1, one bank,
/// version 0), with a fixed serial where Mupen64Plus draws a random one.
Uint8List formattedMempak() {
  const pageSize = 256;
  final pak = Uint8List(N64Layout.pakSize);

  // Page 0: the 32-byte ID block in blocks 1, 3, 4 and 6; the others zero.
  final id = ByteData(32);
  const serial = [0x46524545, 0x474F5359, 0, 0, 0, 0]; // "FREEGOSY"
  for (var i = 0; i < serial.length; i++) {
    id.setUint32(i * 4, serial[i]);
  }
  id
    ..setUint16(24, 0x0001) // device id
    ..setUint8(26, 0x01) // banks
    ..setUint8(27, 0x00); // version
  var sum = 0;
  for (var i = 0; i < 28; i += 2) {
    sum = (sum + id.getUint16(i)) & 0xFFFF;
  }
  id
    ..setUint16(28, sum)
    ..setUint16(30, (0xFFF2 - sum) & 0xFFFF);
  final idBlock = id.buffer.asUint8List();
  for (final block in const [1, 3, 4, 6]) {
    pak.setRange(block * 32, block * 32 + 32, idBlock);
  }

  // Page 1: the index table. Pages 0-4 are reserved; 5-127 are free (0x0003).
  const page1 = pageSize;
  for (var i = 5; i < 128; i++) {
    pak[page1 + 2 * i + 1] = 0x03;
  }
  var tableSum = 0;
  for (var i = page1 + 10; i < page1 + pageSize; i++) {
    tableSum += pak[i];
  }
  pak[page1 + 1] = tableSum & 0xFF;

  // Page 2 backs up page 1; pages 3 and on stay zero.
  pak.setRange(2 * pageSize, 3 * pageSize, Uint8List.sublistView(pak, page1, page1 + pageSize));
  return pak;
}

/// Whether [bytes] hold nothing: erased (0xFF, as the cores format a part)
/// or zeroed (as older Mupen64Plus cores did).
bool _blank(Uint8List bytes) => bytes.every((b) => b == 0xFF) || bytes.every((b) => b == 0);

/// [bytes] at [size], the rest 0xFF (erased); a FormatException when longer.
Uint8List _padded(Uint8List bytes, int size, String what) {
  if (bytes.length > size) {
    throw FormatException('$what is ${bytes.length} bytes; Mupen64Plus keeps at most $size');
  }
  return Uint8List(size)
    ..fillRange(0, size, 0xFF)
    ..setRange(0, bytes.length, bytes);
}

/// Mupen64Plus-Next, ParaLLEl N64 and Mupen64Plus in RetroArch: one
/// `<content>.srm` holding every part (see [N64Layout]).
class N64MupenSrmFormat extends SaveFormat<N64SaveData> {
  const N64MupenSrmFormat();

  @override
  String get id => 'n64.mupen_srm';
  @override
  Set<String> get tags => const {'mupen64plus_next', 'parallel_n64', 'mupen64plus'};

  @override
  bool recognises(List<SaveBlob> files) =>
      files.length == 1 && files.single.extension == '.srm' && files.single.bytes.length >= N64Layout.srmSize;

  @override
  N64SaveData decode(List<SaveBlob> files) {
    if (!recognises(files)) throw const FormatException('not a Mupen64Plus .srm');
    final srm = files.single.bytes;
    Uint8List? part(int offset, int size, {bool swap = false}) {
      final bytes = Uint8List.sublistView(srm, offset, offset + size);
      if (_blank(bytes)) return null;
      return swap ? swapWords(bytes) : Uint8List.fromList(bytes);
    }

    return N64SaveData(
      eeprom: part(0, N64Layout.eepromSize),
      sram: part(N64Layout.sramOffset, N64Layout.sramSize, swap: true),
      flash: part(N64Layout.flashOffset, N64Layout.flashSize, swap: true),
      paks: [
        for (var i = 0; i < 4; i++)
          Uint8List.fromList(Uint8List.sublistView(
              srm, N64Layout.paksOffset + i * N64Layout.pakSize, N64Layout.paksOffset + (i + 1) * N64Layout.pakSize)),
      ],
    );
  }

  @override
  List<SaveBlob> encode(N64SaveData save, {required String stem, List<SaveBlob> existing = const []}) {
    final srm = Uint8List(N64Layout.srmSize)..fillRange(0, N64Layout.srmSize, 0xFF);
    if (save.eeprom != null) {
      srm.setRange(0, N64Layout.eepromSize, _padded(save.eeprom!, N64Layout.eepromSize, 'EEPROM'));
    }
    final paks = save.paks ?? _localPaks(existing, stem) ?? [for (var i = 0; i < 4; i++) formattedMempak()];
    for (var i = 0; i < 4; i++) {
      if (paks[i].length != N64Layout.pakSize) throw FormatException('controller pak $i is ${paks[i].length} bytes');
      srm.setRange(N64Layout.paksOffset + i * N64Layout.pakSize, N64Layout.paksOffset + (i + 1) * N64Layout.pakSize, paks[i]);
    }
    if (save.sram != null) {
      srm.setRange(N64Layout.sramOffset, N64Layout.flashOffset,
          swapWords(_padded(save.sram!, N64Layout.sramSize, 'SRAM')));
    }
    if (save.flash != null) {
      srm.setRange(N64Layout.flashOffset, N64Layout.srmSize,
          swapWords(_padded(save.flash!, N64Layout.flashSize, 'FlashRAM')));
    }
    return [SaveBlob('$stem.srm', srm)];
  }

  /// The controller paks of this game's `.srm` among [existing], kept when
  /// the save comes from an emulator whose saves carry no paks (ares), so a
  /// pull doesn't wipe them.
  List<Uint8List>? _localPaks(List<SaveBlob> existing, String stem) {
    for (final file in existing) {
      if (file.name.toLowerCase() == '$stem.srm'.toLowerCase() && recognises([file])) return decode([file]).paks;
    }
    return null;
  }
}

/// ares: one file per part the game uses (`<rom>.eeprom`, `.ram`, `.flash`),
/// big-endian. ares sizes its memory from its game database and reads
/// `min(size, file size)`, so either EEPROM length loads.
class N64AresFormat extends SaveFormat<N64SaveData> {
  const N64AresFormat();

  static const _extensions = {'.eeprom', '.ram', '.flash'};

  @override
  String get id => 'n64.ares';
  @override
  Set<String> get tags => const {'ares'};

  @override
  bool recognises(List<SaveBlob> files) {
    final extensions = files.map((f) => f.extension).toList();
    return files.isNotEmpty && extensions.every(_extensions.contains) && extensions.toSet().length == files.length;
  }

  @override
  N64SaveData decode(List<SaveBlob> files) {
    if (!recognises(files)) throw const FormatException('not ares N64 save files');
    Uint8List? of(String extension) {
      for (final f in files) {
        if (f.extension == extension) return f.bytes;
      }
      return null;
    }

    final eeprom = of('.eeprom');
    final ram = of('.ram');
    final flash = of('.flash');
    return N64SaveData(
      eeprom: eeprom == null ? null : _padded(eeprom, N64Layout.eepromSize, 'EEPROM'),
      sram: ram == null ? null : _padded(ram, N64Layout.sramSize, 'SRAM'),
      flash: flash == null ? null : _padded(flash, N64Layout.flashSize, 'FlashRAM'),
    );
  }

  @override
  List<SaveBlob> encode(N64SaveData save, {required String stem, List<SaveBlob> existing = const []}) => [
        if (save.eeprom != null) SaveBlob('$stem.eeprom', _eepromFile(save.eeprom!)),
        if (save.sram != null) SaveBlob('$stem.ram', _padded(save.sram!, N64Layout.sramSize, 'SRAM')),
        if (save.flash != null) SaveBlob('$stem.flash', _padded(save.flash!, N64Layout.flashSize, 'FlashRAM')),
      ];

  /// 512 bytes for a 4 Kbit EEPROM (the rest erased), as ares writes it;
  /// else 2048.
  static Uint8List _eepromFile(Uint8List eeprom) {
    final full = _padded(eeprom, N64Layout.eepromSize, 'EEPROM');
    return _blank(Uint8List.sublistView(full, 512)) ? Uint8List.fromList(full.sublist(0, 512)) : full;
  }
}

const n64SaveSystem = SaveSystem<N64SaveData>(
  name: 'N64',
  slugs: {'n64', 'nintendo-64'},
  formats: [N64MupenSrmFormat(), N64AresFormat()],
);
