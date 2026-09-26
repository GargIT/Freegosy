import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';
import 'package:freegosy/core/save/rgba_png.dart';

void main() {
  // 2×2: red, green / blue, half-transparent white.
  final pixels = Uint8List.fromList([
    255, 0, 0, 255, 0, 255, 0, 255, //
    0, 0, 255, 255, 255, 255, 255, 128,
  ]);

  test('writes a PNG signature and an 8-bit RGBA header of the given size', () {
    final png = encodeRgbaPng(2, 2, pixels);

    expect(png.sublist(0, 8), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
    final ihdr = ByteData.sublistView(png, 8);
    expect(String.fromCharCodes(png.sublist(12, 16)), 'IHDR');
    expect(ihdr.getUint32(8), 2, reason: 'width');
    expect(ihdr.getUint32(12), 2, reason: 'height');
    expect(png[24], 8, reason: 'bit depth');
    expect(png[25], 6, reason: 'colour type RGBA');
  });

  testWidgets('decodes back to the same pixels', (tester) async {
    final png = encodeRgbaPng(2, 2, pixels);

    final decoded = await tester.runAsync(() async {
      final codec = await ui.instantiateImageCodec(png);
      final image = (await codec.getNextFrame()).image;
      final data = await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
      return (image.width, image.height, data!.buffer.asUint8List());
    });

    expect(decoded!.$1, 2);
    expect(decoded.$2, 2);
    expect(decoded.$3, pixels);
  });

  test('rejects pixel data that does not match the size', () {
    expect(() => encodeRgbaPng(2, 2, Uint8List(15)), throwsArgumentError);
    expect(() => encodeRgbaPng(0, 2, Uint8List(0)), throwsArgumentError);
  });
}
