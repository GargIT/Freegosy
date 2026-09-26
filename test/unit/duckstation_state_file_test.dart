import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';
import 'package:freegosy/core/save/strategies/duckstation_state_file.dart';
import 'package:path/path.dart' as p;

import '../helpers/duckstation_state_builder.dart';

void main() {
  group('DuckstationStateFile.parseFormatVersion', () {
    test('reads the format version after the DUCC magic', () {
      expect(DuckstationStateFile.parseFormatVersion(duckstationHead()), 86);
      expect(DuckstationStateFile.parseFormatVersion(duckstationHead(version: 55)), 55);
    });

    test('null for another magic, a short head or a zero version', () {
      expect(DuckstationStateFile.parseFormatVersion(duckstationHead(magic: [0x50, 0x4B, 3, 4])), isNull);
      expect(DuckstationStateFile.parseFormatVersion(Uint8List.fromList([0x44, 0x55, 0x43, 0x43, 86])), isNull);
      expect(DuckstationStateFile.parseFormatVersion(Uint8List(0)), isNull);
      expect(DuckstationStateFile.parseFormatVersion(duckstationHead(version: 0)), isNull);
    });
  });

  group('DuckstationStateFile.readFormatVersion', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('duckstation_state_file'));
    tearDown(() => dir.delete(recursive: true));

    test('reads it from the start of a file', () async {
      final file = File(p.join(dir.path, 'SLES-03508_resume.sav'));
      await file.writeAsBytes([...duckstationHead(), ...List.filled(4096, 7)]);

      expect(await DuckstationStateFile.readFormatVersion(file), 86);
    });

    test('null for garbage or a missing file, never throws', () async {
      final garbage = File(p.join(dir.path, 'garbage.sav'));
      await garbage.writeAsBytes(List.filled(300, 0xAB));

      expect(await DuckstationStateFile.readFormatVersion(garbage), isNull);
      expect(await DuckstationStateFile.readFormatVersion(File(p.join(dir.path, 'missing.sav'))), isNull);
    });
  });

  group('DuckstationStateFile.readScreenshot', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('duckstation_screenshot'));
    tearDown(() => dir.delete(recursive: true));

    // 2×2 RGBA: red, green / blue, white.
    final pixels = Uint8List.fromList([
      255, 0, 0, 255, 0, 255, 0, 255, //
      0, 0, 255, 255, 255, 255, 255, 255,
    ]);
    // Stands in for zstd: the "compressed" bytes are the pixels behind a
    // marker, so tests can tell what the reader handed over.
    final compressed = Uint8List.fromList([0x28, 0xB5, 0x2F, 0xFD, ...pixels]);
    final seen = <Uint8List>[];
    Future<Uint8List?> fakeZstd(Uint8List input) async {
      seen.add(input);
      return input.sublist(4);
    }

    setUp(seen.clear);

    Future<File> write(Uint8List bytes) async {
      final file = File(p.join(dir.path, 'SLES-03508_1.sav'));
      await file.writeAsBytes(bytes);
      return file;
    }

    /// Width, height and pixels of [png], decoded by the engine.
    Future<(int, int, Uint8List)> decode(WidgetTester tester, Uint8List png) async =>
        (await tester.runAsync(() async {
          final image = (await (await ui.instantiateImageCodec(png)).getNextFrame()).image;
          final data = await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
          return (image.width, image.height, data!.buffer.asUint8List());
        }))!;

    testWidgets('a zstd screenshot is decompressed and returned as a PNG of the same pixels',
        (tester) async {
      final file = await tester.runAsync(() => write(duckstationState(payload: compressed)));

      final png = await tester.runAsync(() => DuckstationStateFile.readScreenshot(file!, zstd: fakeZstd));

      expect(seen.single, compressed, reason: 'exactly the declared screenshot bytes');
      final (w, h, rgba) = await decode(tester, png!);
      expect((w, h), (2, 2));
      expect(rgba, pixels);
    });

    testWidgets('an uncompressed screenshot is used as it is', (tester) async {
      final file = await tester.runAsync(() => write(duckstationState(payload: pixels, compression: 0)));

      final png = await tester.runAsync(() => DuckstationStateFile.readScreenshot(file!, zstd: fakeZstd));

      expect(seen, isEmpty);
      expect((await decode(tester, png!)).$3, pixels);
    });

    test('null when the decompressed size is not width × height × 4', () async {
      final file = await write(duckstationState(payload: compressed, width: 3));

      expect(await DuckstationStateFile.readScreenshot(file, zstd: fakeZstd), isNull);
    });

    test('null when the decompressor fails or returns nothing', () async {
      final file = await write(duckstationState(payload: compressed));

      expect(await DuckstationStateFile.readScreenshot(file, zstd: (_) async => throw Exception('boom')),
          isNull);
      expect(await DuckstationStateFile.readScreenshot(file, zstd: (_) async => null), isNull);
    });

    test('null for an unsupported compression type', () async {
      final file = await write(duckstationState(payload: compressed, compression: 1));

      expect(await DuckstationStateFile.readScreenshot(file, zstd: fakeZstd), isNull);
      expect(seen, isEmpty);
    });

    test('null when the screenshot lies outside the file or is implausibly large', () async {
      final past = await write(duckstationState(payload: compressed, declaredOffset: 1 << 20));
      expect(await DuckstationStateFile.readScreenshot(past, zstd: fakeZstd), isNull);

      final longer = await write(duckstationState(payload: compressed, declaredSize: 1 << 20));
      expect(await DuckstationStateFile.readScreenshot(longer, zstd: fakeZstd), isNull);

      final huge = await write(duckstationState(payload: compressed, width: 100000, height: 100000));
      expect(await DuckstationStateFile.readScreenshot(huge, zstd: fakeZstd), isNull);

      final empty = await write(duckstationState(payload: compressed, width: 0));
      expect(await DuckstationStateFile.readScreenshot(empty, zstd: fakeZstd), isNull);
      expect(seen, isEmpty, reason: 'nothing is decompressed for a bad header');
    });

    test('null for garbage, a short file or a missing file, never throws', () async {
      final garbage = await write(Uint8List.fromList(List.filled(300, 0xAB)));
      expect(await DuckstationStateFile.readScreenshot(garbage, zstd: fakeZstd), isNull);

      final short = await write(duckstationHead().sublist(0, 100));
      expect(await DuckstationStateFile.readScreenshot(short, zstd: fakeZstd), isNull);

      expect(
          await DuckstationStateFile.readScreenshot(File(p.join(dir.path, 'missing.sav')), zstd: fakeZstd),
          isNull);
    });
  });
}
