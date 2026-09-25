import 'dart:io';
import 'dart:typed_data';
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
}
