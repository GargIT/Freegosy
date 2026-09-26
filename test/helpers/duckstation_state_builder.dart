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

/// A whole DuckStation `.sav` laid out like a real one: the header, the
/// screenshot [payload] right after it (at 0xD8, as a state with an empty
/// disc path), then some state data. The screenshot fields say
/// [compression] (0 none, 2 zstd), [width] × [height], and
/// [declaredSize] / [declaredOffset] when given instead of the real ones.
Uint8List duckstationState({
  required List<int> payload,
  int compression = 2,
  int width = 2,
  int height = 2,
  int? declaredSize,
  int? declaredOffset,
}) {
  final head = duckstationHead();
  ByteData.sublistView(head)
    ..setUint32(0xB4, compression, Endian.little)
    ..setUint32(0xB8, width, Endian.little)
    ..setUint32(0xBC, height, Endian.little)
    ..setUint32(0xC0, declaredSize ?? payload.length, Endian.little)
    ..setUint32(0xC4, declaredOffset ?? head.length, Endian.little);
  return Uint8List.fromList([...head, ...payload, ...List.filled(512, 9)]);
}
