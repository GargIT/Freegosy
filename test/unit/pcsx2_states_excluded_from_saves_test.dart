import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:freegosy/core/romm/romm_models.dart';
import 'package:path/path.dart' as p;

import '../helpers/pcsx2_test_env.dart';

void main() {
  late Directory base;
  late Pcsx2TestEnv env;
  final game = Game(id: 'g1', name: 'Ico (SCUS-97113)', platformSlug: 'ps2', fileSize: 0);
  const stateName = 'SCUS-97113 (A1B2C3D4).01.p2s';

  setUp(() async {
    base = await Directory.systemTemp.createTemp('pcsx2_states_excluded');
    env = await Pcsx2TestEnv.create(base);
  });

  tearDown(() => base.delete(recursive: true));

  Uint8List zip(Map<String, List<int>> entries) {
    final archive = Archive();
    for (final e in entries.entries) {
      archive.addFile(ArchiveFile(e.key, e.value.length, e.value));
    }
    return Uint8List.fromList(ZipEncoder().encode(archive));
  }

  test('getSaveFiles returns the memcard but no save states', () async {
    await File(p.join(env.exeDir, 'memcards', 'Mcd001.ps2')).writeAsBytes(List.filled(150, 1));
    await Directory(env.statesDir).create(recursive: true);
    await File(p.join(env.statesDir, stateName)).writeAsBytes(List.filled(150, 2));

    // fsName makes the legacy ROM-stem match (`SCUS-97113`) occur inside the
    // state's file name, so this fails if the states block is reinstated.
    final stemGame =
        Game(id: 'g1', name: 'Ico', fsName: 'SCUS-97113.iso', platformSlug: 'ps2', fileSize: 0);
    final files = await env.strategy.getSaveFiles(stemGame, p.join(base.path, 'Ico (SCUS-97113).iso'));

    expect(files.map((f) => p.basename(f.path)), ['Mcd001.ps2']);
  });

  test('restoreSave ignores legacy save-state entries inside a saves bundle', () async {
    final bundle = zip({
      'Mcd001.ps2': List.filled(150, 5),
      stateName: List.filled(150, 6),
    });

    final ok = await env.strategy.restoreSave(game, env.exeDir, bundle, 'Ico.zip');

    expect(ok, isTrue);
    expect(await File(p.join(env.exeDir, 'memcards', 'Mcd001.ps2')).exists(), isTrue);
    expect(await File(p.join(env.statesDir, stateName)).exists(), isFalse,
        reason: 'states are synced by StateSyncService, never restored from a saves bundle');
  });

  test('restoreSave ignores a legacy single-file state upload', () async {
    final ok = await env.strategy
        .restoreSave(game, env.exeDir, Uint8List.fromList(List.filled(150, 3)), stateName);

    expect(ok, isTrue);
    expect(await File(p.join(env.statesDir, stateName)).exists(), isFalse);
    expect(await File(p.join(env.exeDir, 'memcards', stateName)).exists(), isFalse);
  });
}
