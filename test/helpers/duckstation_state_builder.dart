import 'dart:typed_data';

/// The start of a DuckStation `.sav`: `DUCC`, a u32 LE format version, the
/// title and serial (the rest of the real 216-byte header is not needed).
Uint8List duckstationHead({int version = 86, List<int> magic = const [0x44, 0x55, 0x43, 0x43]}) {
  final bytes = Uint8List(0xD8);
  bytes.setAll(0, magic);
  ByteData.sublistView(bytes).setUint32(4, version, Endian.little);
  bytes.setAll(0x08, 'Future Racer'.codeUnits);
  bytes.setAll(0x88, 'SLES-03508'.codeUnits);
  return bytes;
}
