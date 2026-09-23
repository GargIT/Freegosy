import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:freegosy/core/romm/romm_models.dart';
import 'package:freegosy/core/storage/directory_service.dart';
import 'package:freegosy/core/storage/rom_lookup_service.dart';
import 'package:freegosy/core/storage/shared_preferences_app_preferences.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// DirectoryService.getRomFilePath() appends `fs_extension` to `fs_name`
/// only when the name doesn't already end with it (issues #96 and #108).
void main() {
  group('DirectoryService.getRomFilePath extension handling', () {
    late Directory tempDir;
    late DirectoryService service;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      tempDir = await Directory.systemTemp.createTemp('rom_file_path_test');
      final prefs = SharedPreferencesAppPreferences(await SharedPreferences.getInstance());
      service = DirectoryService(prefs);
      service.romsRootPath = tempDir.path;
    });

    tearDown(() async {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    Game makeGame({required String fsName, String? fsExtension, String platformSlug = 'snes'}) {
      return Game(
        id: '1',
        name: 'Test Game',
        fsName: fsName,
        fsExtension: fsExtension,
        platformSlug: platformSlug,
        fileSize: 0,
      );
    }

    test('appends fs_extension when fs_name lacks it (issue #96)', () async {
      final game = makeGame(fsName: 'Game', fsExtension: 'iso', platformSlug: 'ps2');
      final path = await service.getRomFilePath(game);
      expect(p.basename(path), 'Game.iso');
    });

    test('does not duplicate a simple extension already on fs_name', () async {
      final game = makeGame(fsName: 'Game.sfc', fsExtension: 'sfc');
      final path = await service.getRomFilePath(game);
      expect(p.basename(path), 'Game.sfc');
    });

    test('does not duplicate a compound extension already on fs_name (issue #108)', () async {
      final game = makeGame(fsName: 'Super Mario Kart (USA).sfc.zip', fsExtension: 'sfc.zip');
      final path = await service.getRomFilePath(game);
      expect(p.basename(path), 'Super Mario Kart (USA).sfc.zip');
    });

    test('extension comparison is case-insensitive', () async {
      final game = makeGame(fsName: 'Game.SFC.ZIP', fsExtension: 'sfc.zip');
      final path = await service.getRomFilePath(game);
      expect(p.basename(path), 'Game.SFC.ZIP');
    });

    test('appends compound extension when fs_name lacks it', () async {
      final game = makeGame(fsName: 'Game', fsExtension: 'sfc.zip');
      final path = await service.getRomFilePath(game);
      expect(p.basename(path), 'Game.sfc.zip');
    });

    test('downloaded compound-extension ROM is found by lookup (issue #108)', () async {
      final game = makeGame(fsName: 'Super Mario Kart (USA).sfc.zip', fsExtension: 'sfc.zip');
      final path = await service.getRomFilePath(game);
      await File(path).writeAsString('rom');

      final found = await RomLookupService.findExistingRomPath(game, p.dirname(path));
      expect(found, isNotNull);
      expect(p.basename(found!), 'Super Mario Kart (USA).sfc.zip');
    });
  });
}
