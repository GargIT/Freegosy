import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:freegosy/core/romm/romm_models.dart';
import 'package:freegosy/core/save/save_strategy.dart';
import 'package:freegosy/core/save/state_sync_capable.dart';
import 'package:freegosy/core/save/state_sync_service.dart';
import 'package:freegosy/core/save/strategies/pcsx2_save_strategy.dart';
import 'package:path/path.dart' as p;

import '../helpers/pcsx2_test_env.dart';

/// Implements only the required StateSyncCapable members, so it exercises the
/// mixin's default `autoLoadState`.
class _MinimalStateStrategy extends SaveStrategy with StateSyncCapable {
  @override
  String get strategyId => 'minimal';

  @override
  Future<String?> getSaveDir(Game game, String romPath) async => null;

  @override
  Future<List<File>> getSaveFiles(Game game, String romPath,
          {DateTime? sessionStart, String syncMode = 'both'}) async =>
      [];

  @override
  Future<bool> restoreSave(
          Game game, String destPath, Uint8List data, String filename) async =>
      false;

  @override
  Future<String> stateDirectory(Game game, String romPath) async => '';

  @override
  Future<bool Function(String fileName)?> stateFileMatcher(
          Game game, String romPath) async =>
      null;
}

void main() {
  late Directory base;
  late Pcsx2TestEnv env;
  final game = Game(id: 'g1', name: 'Ico (SCUS-97113)', platformSlug: 'ps2', fileSize: 0);

  setUp(() async {
    base = await Directory.systemTemp.createTemp('pcsx2_autoload');
    env = await Pcsx2TestEnv.create(base);
  });

  tearDown(() => base.delete(recursive: true));

  String romPath() => p.join(base.path, 'Ico (SCUS-97113).iso');

  File writeState(String name, {int bytes = 200, DateTime? modified}) {
    final file = File(p.join(env.statesDir, name))
      ..createSync(recursive: true)
      ..writeAsBytesSync(List.filled(bytes, 7));
    if (modified != null) file.setLastModifiedSync(modified);
    return file;
  }

  test('returns the resume state of the game', () async {
    final resume = writeState('SCUS-97113 (A1B2C3D4).resume.p2s');

    final found = await env.strategy.autoLoadState(game, romPath());

    expect(found?.path, resume.path);
  });

  test('never returns a numbered quick-save slot', () async {
    writeState('SCUS-97113 (A1B2C3D4).01.p2s');
    writeState('SCUS-97113 (A1B2C3D4).10.p2s');

    expect(await env.strategy.autoLoadState(game, romPath()), isNull);
  });

  test('prefers the resume state over newer numbered slots', () async {
    final resume = writeState('SCUS-97113 (A1B2C3D4).resume.p2s',
        modified: DateTime(2026, 1, 1));
    writeState('SCUS-97113 (A1B2C3D4).01.p2s', modified: DateTime(2026, 6, 1));

    expect((await env.strategy.autoLoadState(game, romPath()))?.path, resume.path);
  });

  test('ignores backups, other games and files that are too small', () async {
    writeState('SCUS-97113 (A1B2C3D4).resume.p2s.backup');
    writeState('SCUS-97113 (A1B2C3D4).resume.p2s.bak');
    writeState('SLUS-20312 (A1B2C3D4).resume.p2s');
    writeState('SCUS-97113 (A1B2C3D4).resume.p2s', bytes: 99);

    expect(await env.strategy.autoLoadState(game, romPath()), isNull);
  });

  test('matches the game serial ignoring case and punctuation', () async {
    final resume = writeState('scus_97113 (A1B2C3D4).resume.p2s');

    expect((await env.strategy.autoLoadState(game, romPath()))?.path, resume.path);
  });

  test('the size floor is the same as state sync\'s', () {
    expect(Pcsx2SaveStrategy.minAutoLoadStateBytes, StateSyncService.minValidStateBytes);
  });

  test('accepts a file of exactly 100 bytes', () async {
    final resume = writeState('SCUS-97113 (A1B2C3D4).resume.p2s', bytes: 100);

    expect((await env.strategy.autoLoadState(game, romPath()))?.path, resume.path);
  });

  test('ignores a directory that looks like a resume state', () async {
    Directory(p.join(env.statesDir, 'SCUS-97113 (A1B2C3D4).resume.p2s'))
        .createSync(recursive: true);

    expect(await env.strategy.autoLoadState(game, romPath()), isNull);
  });

  test('takes the newest resume state when several CRCs match the serial', () async {
    writeState('SCUS-97113 (AAAAAAAA).resume.p2s', modified: DateTime(2026, 1, 1));
    final newest = writeState('SCUS-97113 (BBBBBBBB).resume.p2s',
        modified: DateTime(2026, 3, 1));
    writeState('SCUS-97113 (CCCCCCCC).resume.p2s', modified: DateTime(2026, 2, 1));

    expect((await env.strategy.autoLoadState(game, romPath()))?.path, newest.path);
  });

  test('is null when the states folder does not exist', () async {
    expect(Directory(env.statesDir).existsSync(), isFalse);

    expect(await env.strategy.autoLoadState(game, romPath()), isNull);
  });

  test('is null when the game serial cannot be determined', () async {
    writeState('SCUS-97113 (A1B2C3D4).resume.p2s');
    final unknown = Game(id: 'g2', name: 'No Serial Here', platformSlug: 'ps2', fileSize: 0);

    expect(await env.strategy.autoLoadState(unknown, p.join(base.path, 'No Serial Here.iso')),
        isNull);
  });

  test('StateSyncCapable default is no auto-load state', () async {
    expect(await _MinimalStateStrategy().autoLoadState(game, romPath()), isNull);
  });

  test('stateAutoLoadKey is per emulator', () {
    expect(stateAutoLoadKey('pcsx2'), 'state_autoload_enabled_pcsx2');
  });
}
