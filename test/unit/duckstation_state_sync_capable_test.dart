import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:freegosy/core/romm/romm_models.dart';
import 'package:freegosy/core/save/save_state_info.dart';
import 'package:freegosy/core/save/state_sync_capable.dart';
import 'package:path/path.dart' as p;

import '../helpers/duckstation_state_builder.dart';
import '../helpers/duckstation_test_env.dart';

void main() {
  late Directory base;
  late DuckstationTestEnv env;
  final game = Game(id: 'g1', name: 'Future Racer (SLES-03508)', platformSlug: 'psx', fileSize: 0);
  const stateName = 'SLES-03508_resume.sav';

  setUp(() async {
    base = await Directory.systemTemp.createTemp('duckstation_state_caps');
    env = await DuckstationTestEnv.create(base);
  });

  tearDown(() => base.delete(recursive: true));

  String romPath() => p.join(base.path, 'Future Racer (SLES-03508).chd');

  test('DuckstationSaveStrategy is StateSyncCapable', () {
    expect(env.strategy, isA<StateSyncCapable>());
  });

  test('stateDirectory is <portable root>/savestates', () async {
    final strategy = env.strategy as StateSyncCapable;
    expect(await strategy.stateDirectory(game, romPath()), env.statesDir);
  });

  test('matcher accepts the resume state and numbered slots for the game\'s serial', () async {
    final matches = (await (env.strategy as StateSyncCapable).stateFileMatcher(game, romPath()))!;

    expect(matches('SLES-03508_resume.sav'), isTrue);
    expect(matches('SLES-03508_1.sav'), isTrue);
    expect(matches('SLES-03508_10.sav'), isTrue);
    expect(matches('sles-03508_2.sav'), isTrue, reason: 'serials compare case-insensitively');
  });

  test('matcher rejects other serials, backups, global slots and path tricks', () async {
    final matches = (await (env.strategy as StateSyncCapable).stateFileMatcher(game, romPath()))!;

    expect(matches('SLUS-00594_resume.sav'), isFalse, reason: 'another game');
    expect(matches('SLES-03508_resume.sav.backup'), isFalse, reason: 'DuckStation backup');
    expect(matches('SLES-03508_1.sav.bak'), isFalse, reason: 'Freegosy backup');
    expect(matches('SLES-03508_1.sav.freegosy_tmp'), isFalse);
    expect(matches('savestate_1.sav'), isFalse, reason: 'global slot, not tied to a game');
    expect(matches('SLES-03508_1.mcd'), isFalse);
    expect(matches(r'..\SLES-03508_resume.sav'), isFalse, reason: 'path traversal');
    expect(matches('../SLES-03508_resume.sav'), isFalse, reason: 'path traversal');
    expect(matches('SLES-035080_resume.sav'), isFalse, reason: 'a longer serial');
  });

  test('matcher is null when the game serial cannot be determined', () async {
    final unknown = Game(id: 'g2', name: 'No Serial Here', platformSlug: 'psx', fileSize: 0);
    final strategy = env.strategy as StateSyncCapable;

    expect(await strategy.stateFileMatcher(unknown, p.join(base.path, 'No Serial Here.iso')), isNull);
  });

  test('looksLikeValidState requires the DUCC header', () {
    final strategy = env.strategy as StateSyncCapable;
    expect(strategy.looksLikeValidState(duckstationHead()), isTrue);
    expect(strategy.looksLikeValidState(Uint8List.fromList([0x50, 0x4B, 3, 4, 0])), isFalse);
    expect(strategy.looksLikeValidState(Uint8List(0)), isFalse);
  });

  test('slotOf names the resume state and numbered slots', () {
    final strategy = env.strategy as StateSyncCapable;
    expect(strategy.slotOf('SLES-03508_resume.sav'), isA<AutoStateSlot>());
    expect((strategy.slotOf('SLES-03508_3.sav') as NumberedStateSlot).number, 3);
    expect(strategy.slotOf('SLES-03508_10.sav'), const NumberedStateSlot(10));
    expect(strategy.slotOf('savestate_1.sav'), isA<UnknownStateSlot>());
  });

  test('describeState reports the format version and the file time, no emulator version', () async {
    await Directory(env.statesDir).create(recursive: true);
    final file = File(p.join(env.statesDir, stateName));
    await file.writeAsBytes([...duckstationHead(), ...List.filled(4096, 1)]);
    final saved = DateTime(2026, 9, 20, 18, 30);
    await file.setLastModified(saved);

    final info = await (env.strategy as StateSyncCapable).describeState(file);

    expect(info.savedAt, saved);
    expect(info.formatId, '86');
    expect(info.emulatorVersion, isNull);
  });

  test('describeState of a garbage file has no format and does not throw', () async {
    await Directory(env.statesDir).create(recursive: true);
    final file = File(p.join(env.statesDir, stateName));
    await file.writeAsBytes(List.filled(300, 0xAB));

    final info = await (env.strategy as StateSyncCapable).describeState(file);

    expect(info.formatId, isNull);
    expect(info.emulatorVersion, isNull);
  });

  test('stateScreenshot returns the state\'s screenshot as a PNG, through the given zstd', () async {
    final pixels = List.filled(2 * 2 * 4, 200);
    final screenshotEnv = await DuckstationTestEnv.create(
        await base.createTemp('shot'),
        zstd: (compressed) async => Uint8List.fromList(pixels));
    await Directory(screenshotEnv.statesDir).create(recursive: true);
    final file = File(p.join(screenshotEnv.statesDir, stateName));
    await file.writeAsBytes(duckstationState(payload: [0x28, 0xB5, 0x2F, 0xFD, 1, 2, 3]));

    final png = await (screenshotEnv.strategy as StateSyncCapable).stateScreenshot(file);

    expect(png, isNotNull);
    expect(png!.sublist(1, 4), 'PNG'.codeUnits);
  });

  test('stateScreenshot is null for a state without a readable screenshot', () async {
    await Directory(env.statesDir).create(recursive: true);
    final file = File(p.join(env.statesDir, stateName));
    await file.writeAsBytes(List.filled(300, 0xAB));

    expect(await (env.strategy as StateSyncCapable).stateScreenshot(file), isNull);
  });

  group('states stay out of the memory-card save', () {
    Uint8List zip(Map<String, List<int>> entries) {
      final archive = Archive();
      for (final e in entries.entries) {
        archive.addFile(ArchiveFile(e.key, e.value.length, e.value));
      }
      return Uint8List.fromList(ZipEncoder().encode(archive));
    }

    test('getSaveFiles returns the memory card but no save states', () async {
      await File(p.join(env.memcardsDir, 'shared_card_1.mcd')).writeAsBytes(List.filled(150, 1));
      await Directory(env.statesDir).create(recursive: true);
      await File(p.join(env.statesDir, stateName)).writeAsBytes(List.filled(150, 2));

      // fsName makes the old ROM-stem match (`SLES-03508`) occur inside the
      // state's file name, so this fails if the states block comes back.
      final stemGame = Game(
          id: 'g1', name: 'Future Racer', fsName: 'SLES-03508.chd', platformSlug: 'psx', fileSize: 0);
      final files = await env.strategy.getSaveFiles(stemGame, romPath());

      expect(files.map((f) => p.basename(f.path)), ['shared_card_1.mcd']);
    });

    test('restoreSave ignores state entries inside a saves bundle', () async {
      final bundle = zip({
        'shared_card_1.mcd': List.filled(150, 5),
        stateName: List.filled(150, 6),
      });

      final ok = await env.strategy.restoreSave(game, env.exeDir, bundle, 'Future Racer.zip');

      expect(ok, isTrue);
      expect(await File(p.join(env.memcardsDir, 'shared_card_1.mcd')).exists(), isTrue);
      expect(await File(p.join(env.statesDir, stateName)).exists(), isFalse,
          reason: 'states are synced by StateSyncService, never restored from a saves bundle');
    });

    test('restoreSave ignores a single-file state upload', () async {
      final ok = await env.strategy
          .restoreSave(game, env.exeDir, Uint8List.fromList(List.filled(150, 3)), stateName);

      expect(ok, isTrue);
      expect(await File(p.join(env.statesDir, stateName)).exists(), isFalse);
    });
  });
}
