import 'dart:typed_data';

/// One save to place on a test memory card: its directory [name], the data
/// [blocks] (1–15) it occupies in chain order, and the byte its data is
/// filled with.
typedef TestSave = ({String name, List<int> blocks, int fill});

/// A raw 128 KB PS1 memory card laid out the way DuckStation formats one
/// (header, free directory, broken-sector list, zeroed frames, 0xFF blocks),
/// with [saves] written in, built without the code under test.
Uint8List buildPs1Card(List<TestSave> saves, {int writeTestByte = 0}) {
  final card = Uint8List(128 * 1024)..fillRange(8192, 128 * 1024, 0xFF);
  Uint8List frame(int n) => Uint8List.sublistView(card, n * 128, n * 128 + 128);
  void checksum(Uint8List f) => f[127] = f.sublist(0, 127).fold<int>(0, (a, b) => a ^ b);

  frame(0)
    ..[0] = 0x4D
    ..[1] = 0x43;
  checksum(frame(0));
  for (var i = 1; i < 16; i++) {
    final f = frame(i)
      ..[0] = 0xA0
      ..[8] = 0xFF
      ..[9] = 0xFF;
    checksum(f);
  }
  for (var i = 16; i < 36; i++) {
    final f = frame(i)..fillRange(0, 4, 0xFF);
    f[8] = 0xFF;
    f[9] = 0xFF;
    checksum(f);
  }
  frame(63).setAll(0, frame(0));
  frame(63)[5] = writeTestByte; // games scribble here; must not matter

  for (final save in saves) {
    for (var k = 0; k < save.blocks.length; k++) {
      final block = save.blocks[k];
      card.fillRange(block * 8192, block * 8192 + 8192, save.fill);
      card[block * 8192] = k; // tell the blocks of one save apart
      final last = k == save.blocks.length - 1;
      final entry = frame(block)..fillRange(0, 128, 0);
      final data = ByteData.sublistView(entry);
      data.setUint32(0, save.blocks.length == 1 || k == 0 ? 0x51 : (last ? 0x53 : 0x52), Endian.little);
      data.setUint32(4, k == 0 ? save.blocks.length * 8192 : 0, Endian.little);
      data.setUint16(8, last ? 0xFFFF : save.blocks[k + 1] - 1, Endian.little);
      if (k == 0) entry.setAll(0x0A, save.name.codeUnits);
      checksum(entry);
    }
  }
  return card;
}

/// The directory entry state of [block] on [card].
int entryState(Uint8List card, int block) =>
    ByteData.sublistView(card, block * 128, block * 128 + 4).getUint32(0, Endian.little);

/// The data of [block] on [card].
Uint8List blockData(Uint8List card, int block) => card.sublist(block * 8192, block * 8192 + 8192);
