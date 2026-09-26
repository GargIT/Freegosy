import 'dart:typed_data';
import 'package:archive/archive.dart';

/// A PNG of [width] × [height] 8-bit RGBA [rgba] pixels (rows top to bottom),
/// for emulators that store a state's screenshot as raw pixels. Every row
/// uses filter type 0 (none): simple, and the zlib pass still compresses it.
Uint8List encodeRgbaPng(int width, int height, Uint8List rgba) {
  if (width <= 0 || height <= 0 || rgba.length != width * height * 4) {
    throw ArgumentError('expected ${width}x$height RGBA pixels, got ${rgba.length} bytes');
  }
  final rowBytes = width * 4;
  final raw = Uint8List(height * (rowBytes + 1));
  for (var y = 0; y < height; y++) {
    raw.setRange(y * (rowBytes + 1) + 1, (y + 1) * (rowBytes + 1), rgba, y * rowBytes);
  }

  final out = BytesBuilder(copy: false)
    ..add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  void chunk(String type, List<int> data) {
    final body = Uint8List(4 + data.length)
      ..setAll(0, type.codeUnits)
      ..setAll(4, data);
    out
      ..add((ByteData(4)..setUint32(0, data.length)).buffer.asUint8List())
      ..add(body)
      ..add((ByteData(4)..setUint32(0, getCrc32(body))).buffer.asUint8List());
  }

  final header = ByteData(13)
    ..setUint32(0, width)
    ..setUint32(4, height)
    ..setUint8(8, 8) // bit depth
    ..setUint8(9, 6); // colour type: RGBA
  chunk('IHDR', header.buffer.asUint8List());
  chunk('IDAT', const ZLibEncoder().encode(raw));
  chunk('IEND', const []);
  return out.toBytes();
}
