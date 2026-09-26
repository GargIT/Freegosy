import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:freegosy/core/emulator/strategy_registry.dart';
import 'package:freegosy/core/romm/romm_models.dart';
import 'package:freegosy/core/save/save_strategy.dart';
import 'package:freegosy/core/save/save_sync_service.dart';
import 'package:freegosy/core/save/strategies/duckstation_config.dart';
import 'package:freegosy/core/storage/shared_preferences_app_preferences.dart';
import 'package:mockito/mockito.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/duckstation_test_env.dart';
import 'save_sync_service_test.mocks.dart';

void main() {
  late Directory base;
  late DuckstationTestEnv env;
  final game = Game(
      id: 'g1',
      name: 'Colin McRae Rally 2.0',
      fsName: 'Colin McRae Rally 2.0 (Europe) (SLES-02605).chd',
      platformSlug: 'psx',
      fileSize: 0);
  const saveName = 'Colin McRae Rally 2.0 (Europe) (En,Fr,De,Es,It)';
  const gamedb = 'SLES-02605:\n  name: "Colin McRae Rally 2.0"\n  saveName: "$saveName"\n';

  setUp(() async {
    DuckstationGameDb.clearCache();
    base = await Directory.systemTemp.createTemp('duckstation_memcards');
    env = await DuckstationTestEnv.create(base);
  });

  tearDown(() => base.delete(recursive: true));

  String romPath() => p.join(base.path, 'Colin McRae Rally 2.0 (Europe) (SLES-02605).chd');
  Future<void> cardTypes(String types) => env.writeSettings('[MemoryCards]\n$types\n');
  Future<List<String>> saveFiles() async =>
      (await env.strategy.getSaveFiles(game, romPath())).map((f) => p.basename(f.path)).toList();
  /// The memory cards on disk (not the .bak copies made before overwriting).
  List<String> cardsOnDisk() => Directory(env.memcardsDir)
      .listSync()
      .map((e) => p.basename(e.path))
      .where((name) => name.endsWith('.mcd'))
      .toList()
    ..sort();

  Uint8List zip(Map<String, List<int>> entries) {
    final archive = Archive();
    for (final e in entries.entries) {
      archive.addFile(ArchiveFile(e.key, e.value.length, e.value));
    }
    return Uint8List.fromList(ZipEncoder().encode(archive));
  }

  group('which cards are uploaded', () {
    setUp(() async {
      await env.writeCard('SLES-02605_1.mcd');
      await env.writeCard('Colin McRae Rally 2.0 (Europe) (SLES-02605)_1.mcd');
      await env.writeCard('${saveName}_1.mcd');
      await env.writeCard('shared_card_1.mcd');
      await env.writeCard('Another Game_1.mcd');
    });

    test('by serial: <serial>_1.mcd only', () async {
      await cardTypes('Card1Type = PerGame');
      expect(await saveFiles(), ['SLES-02605_1.mcd']);
    });

    test('by file title: <ROM file name>_1.mcd only', () async {
      await cardTypes('Card1Type = PerGameFileTitle');
      expect(await saveFiles(), ['Colin McRae Rally 2.0 (Europe) (SLES-02605)_1.mcd']);
    });

    test('by title: the saveName from DuckStation\'s own game database', () async {
      await cardTypes('Card1Type = PerGameTitle');
      await env.writeGameDb(gamedb);
      expect(await saveFiles(), ['${saveName}_1.mcd']);
    });

    test('by title with no game database: an existing card matched by name', () async {
      await cardTypes('Card1Type = PerGameTitle');
      final files = await saveFiles();
      expect(files, hasLength(1));
      expect(files.single, isNot('shared_card_1.mcd'));
      expect(files.single, contains('Colin McRae Rally 2.0'));
    });

    test('both ports per game: both cards', () async {
      await cardTypes('Card1Type = PerGame\nCard2Type = PerGame');
      await env.writeCard('SLES-02605_2.mcd');
      expect(await saveFiles(), ['SLES-02605_1.mcd', 'SLES-02605_2.mcd']);
    });

    test('a per-game port next to a shared one: only the per-game card', () async {
      await cardTypes('Card1Type = PerGame\nCard2Type = Shared');
      await env.writeCard('shared_card_2.mcd');
      expect(await saveFiles(), ['SLES-02605_1.mcd']);
    });

    test('only shared: the shared card, for local backups (sync is blocked)', () async {
      await cardTypes('Card1Type = Shared');
      expect(await saveFiles(), ['shared_card_1.mcd']);
    });

    test('the game\'s own settings win over the global ones', () async {
      await cardTypes('Card1Type = Shared');
      await env.writeGameSettings('SLES-02605', '[MemoryCards]\nCard1Type = PerGame\n');
      expect(await saveFiles(), ['SLES-02605_1.mcd']);
    });

    test('the memory card folder follows the Directory setting', () async {
      final elsewhere = Directory(p.join(base.path, 'elsewhere'))..createSync();
      File(p.join(elsewhere.path, 'SLES-02605_1.mcd')).writeAsBytesSync(List.filled(64, 1));
      await cardTypes('Card1Type = PerGame\nDirectory = ${elsewhere.path}');

      final files = await env.strategy.getSaveFiles(game, romPath());

      expect(files.single.path, p.join(elsewhere.path, 'SLES-02605_1.mcd'));
      expect(await env.strategy.getSaveDir(game, romPath()), elsewhere.path);
    });
  });

  group('restoring under this PC\'s names', () {
    test('a card made by serial is written under the title this PC uses', () async {
      await env.writeGameDb(gamedb); // default settings: by title
      final ok = await env.strategy
          .restoreSave(game, romPath(), Uint8List.fromList(List.filled(64, 7)), 'SLES-02605_1.mcd');

      expect(ok, isTrue);
      expect(cardsOnDisk(), ['${saveName}_1.mcd']);
      expect(File(p.join(env.memcardsDir, '${saveName}_1.mcd')).readAsBytesSync().first, 7);
    });

    test('a card made by title is written by file title, keeping its port', () async {
      await cardTypes('Card1Type = PerGameFileTitle\nCard2Type = PerGameFileTitle');
      final bundle = zip({'${saveName}_1.mcd': List.filled(64, 1), '${saveName}_2.mcd': List.filled(64, 2)});

      await env.strategy.restoreSave(game, romPath(), bundle, 'Colin.zip');

      expect(cardsOnDisk(), [
        'Colin McRae Rally 2.0 (Europe) (SLES-02605)_1.mcd',
        'Colin McRae Rally 2.0 (Europe) (SLES-02605)_2.mcd',
      ]);
    });

    test('a card for a port that has no per-game card here is skipped', () async {
      await cardTypes('Card1Type = PerGame\nCard2Type = None');
      final bundle = zip({'SLES-02605_1.mcd': List.filled(64, 1), 'SLES-02605_2.mcd': List.filled(64, 2)});

      await env.strategy.restoreSave(game, romPath(), bundle, 'Colin.zip');

      expect(cardsOnDisk(), ['SLES-02605_1.mcd']);
    });

    test('an old upload of a shared card loses to the game\'s own card in the same bundle', () async {
      await cardTypes('Card1Type = PerGame');
      final bundle = zip({'SLES-02605_1.mcd': List.filled(64, 9), 'shared_card_1.mcd': List.filled(64, 3)});

      await env.strategy.restoreSave(game, romPath(), bundle, 'Colin.zip');

      expect(cardsOnDisk(), ['SLES-02605_1.mcd']);
      expect(File(p.join(env.memcardsDir, 'SLES-02605_1.mcd')).readAsBytesSync().first, 9);
    });

    test('by title with no game database and no card yet: named after the ROM without tags', () async {
      await env.strategy
          .restoreSave(game, romPath(), Uint8List.fromList(List.filled(64, 1)), 'SLES-02605_1.mcd');

      expect(cardsOnDisk(), ['Colin McRae Rally 2.0_1.mcd']);
    });

    test('by title with no game database: an existing card is updated in place', () async {
      await env.writeCard('Colin McRae Rally 2.0 (Europe)_1.mcd', fill: 1);

      await env.strategy
          .restoreSave(game, romPath(), Uint8List.fromList(List.filled(64, 5)), 'SLES-02605_1.mcd');

      expect(cardsOnDisk(), ['Colin McRae Rally 2.0 (Europe)_1.mcd']);
      expect(File(p.join(env.memcardsDir, 'Colin McRae Rally 2.0 (Europe)_1.mcd')).readAsBytesSync().first, 5);
    });

    test('by serial when the serial can\'t be read: nothing is written', () async {
      await cardTypes('Card1Type = PerGame');
      final unknown = Game(id: 'g2', name: 'No Serial', platformSlug: 'psx', fileSize: 0);

      final ok = await env.strategy.restoreSave(unknown, p.join(base.path, 'No Serial.iso'),
          Uint8List.fromList(List.filled(64, 1)), 'SLES-02605_1.mcd');

      expect(ok, isTrue);
      expect(Directory(env.memcardsDir).listSync(), isEmpty);
    });
  });

  group('when sync is not possible', () {
    test('one shared card: blocked, telling the user to choose a card per game', () async {
      await cardTypes('Card1Type = Shared');
      final reason = await env.strategy.saveSyncBlockedReason(game, romPath());
      expect(reason, contains('shared by all games'));
      expect(reason, contains('Separate Card Per Game'));
    });

    test('no card or a non-persistent one: blocked, nothing to sync', () async {
      await cardTypes('Card1Type = NonPersistent');
      expect(await env.strategy.saveSyncBlockedReason(game, romPath()), contains('nothing to sync'));
      await cardTypes('Card1Type = None');
      expect(await env.strategy.saveSyncBlockedReason(game, romPath()), contains('nothing to sync'));
    });

    test('any per-game port: not blocked (default settings included)', () async {
      expect(await env.strategy.saveSyncBlockedReason(game, romPath()), isNull);
      await cardTypes('Card1Type = Shared\nCard2Type = PerGame');
      expect(await env.strategy.saveSyncBlockedReason(game, romPath()), isNull);
    });

    test('a per-game override lifts a global shared card', () async {
      await cardTypes('Card1Type = Shared');
      await env.writeGameSettings('SLES-02605', '[MemoryCards]\nCard1Type = PerGameTitle\n');
      expect(await env.strategy.saveSyncBlockedReason(game, romPath()), isNull);
    });

    test('SaveSyncService push and pull stop before contacting RomM', () async {
      await cardTypes('Card1Type = Shared');
      SharedPreferences.setMockInitialValues({});
      final prefs = SharedPreferencesAppPreferences(await SharedPreferences.getInstance());
      final romm = MockRommService();
      final sync = SaveSyncService(romm, env.directoryService, StrategyRegistry(env.directoryService, prefs), prefs);

      await expectLater(sync.pushSaves(game, romPath(), emulatorId: 'duckstation'),
          throwsA(isA<SaveSyncNotPossibleException>()));
      await expectLater(sync.pullSave(game, romPath(), emulatorId: 'duckstation'),
          throwsA(isA<SaveSyncNotPossibleException>()));
      verifyNever(romm.fetchCapabilities());
    });
  });
}
