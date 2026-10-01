import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:freegosy/core/platform/platform_info.dart';
import 'package:freegosy/core/romm/romm_models.dart';
import 'package:freegosy/core/save/save_strategy.dart';
import 'package:freegosy/core/save/strategies/melonds_save_strategy.dart';
import 'package:freegosy/core/storage/directory_service.dart';
import 'package:freegosy/core/storage/shared_preferences_app_preferences.dart';

/// Issue #24: a different game's save must never be picked up (uploaded) or
/// overwritten (pulled) for this game, and pulled saves must land where the
/// emulator reads them.
void main() {
  late Directory tmp;
  late MelonDsSaveStrategy strategy;
  late String romDir;
  late String romPath;
  final game = Game(id: '1', name: 'Test Monster - White Version', fileSize: 0, platformSlug: 'nds');

  Future<File> put(String dir, String name, List<int> bytes) async {
    await Directory(dir).create(recursive: true);
    return File(p.join(dir, name))..writeAsBytesSync(bytes);
  }

  Future<void> build({String os = 'macos', Map<String, String>? env}) async {
    final prefs = SharedPreferencesAppPreferences(await SharedPreferences.getInstance());
    final dirs = DirectoryService(prefs);
    await dirs.setEmulatorsRoot(p.join(tmp.path, 'emus'));
    strategy = MelonDsSaveStrategy(dirs, platform: PlatformInfo(os, environment: env ?? {'HOME': tmp.path}));
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('melonds_other_');
    romDir = p.join(tmp.path, 'roms', 'nds');
    romPath = p.join(romDir, 'Test Monster - White Version.nds');
    await build();
  });

  tearDown(() => tmp.delete(recursive: true));

  group('upload side (getSaveFiles)', () {
    test('ignores another game sharing a title word', () async {
      await put(romDir, 'Test Monster - Black Version.sav', [1]);
      expect(await strategy.getSaveFiles(game, romPath), isEmpty);
    });

    test('finds <rom>.sav', () async {
      final f = await put(romDir, 'Test Monster - White Version.sav', [1]);
      expect((await strategy.getSaveFiles(game, romPath)).map((e) => e.path), [f.path]);
    });

    test('finds <rom>.srm', () async {
      final f = await put(romDir, 'Test Monster - White Version.srm', [1]);
      expect((await strategy.getSaveFiles(game, romPath)).map((e) => e.path), [f.path]);
    });

    test('finds the web player timestamped name', () async {
      final f = await put(romDir, 'Test Monster - White Version [2026-10-01 14-38-41-643].srm', [1]);
      expect((await strategy.getSaveFiles(game, romPath)).map((e) => e.path), [f.path]);
    });

    test('picks the right save when both games have one', () async {
      await put(romDir, 'Test Monster - Black Version.sav', [1]);
      final mine = await put(romDir, 'Test Monster - White Version.sav', [2]);
      expect((await strategy.getSaveFiles(game, romPath)).map((e) => e.path), [mine.path]);
    });

    test('matching is case-insensitive', () async {
      final f = await put(romDir, 'TEST MONSTER - WHITE VERSION.SAV', [1]);
      expect((await strategy.getSaveFiles(game, romPath)).map((e) => e.path), [f.path]);
    });

    test('a ROM name that merely starts the same is not a match', () async {
      await put(romDir, 'Test Monster - White Version 2.sav', [1]);
      expect(await strategy.getSaveFiles(game, romPath), isEmpty);
    });

    test('non-save files with the right name are ignored', () async {
      await put(romDir, 'Test Monster - White Version.nds.bak', [1]);
      await put(romDir, 'Test Monster - White Version.txt', [1]);
      expect(await strategy.getSaveFiles(game, romPath), isEmpty);
    });

    test('a save older than the session is skipped', () async {
      final f = await put(romDir, 'Test Monster - White Version.sav', [1]);
      f.setLastModifiedSync(DateTime.now().subtract(const Duration(hours: 1)));
      expect(await strategy.getSaveFiles(game, romPath, sessionStart: DateTime.now()), isEmpty);
    });

    test('Windows: save in AppData melonDS is found, another game there is not', () async {
      final appData = p.join(tmp.path, 'AppData');
      await build(os: 'windows', env: {'APPDATA': appData, 'USERPROFILE': tmp.path});
      await put(p.join(appData, 'melonDS'), 'Test Monster - Black Version.sav', [1]);
      expect(await strategy.getSaveFiles(game, romPath), isEmpty);
      final mine = await put(p.join(appData, 'melonDS'), 'Test Monster - White Version.sav', [2]);
      expect((await strategy.getSaveFiles(game, romPath)).map((e) => e.path), [mine.path]);
    });
  });

  group('pull side (restoreSave)', () {
    test('does not overwrite another game save', () async {
      final other = await put(romDir, 'Test Monster - Black Version.sav', [1, 2, 3]);
      await strategy.restoreSave(game, romPath, Uint8List.fromList([9, 9, 9]), 'x.sav');
      expect(other.readAsBytesSync(), [1, 2, 3]);
    });

    test('with no save yet, writes <rom>.sav next to the ROM (not into AppData)', () async {
      final appData = p.join(tmp.path, 'AppData');
      await Directory(p.join(appData, 'melonDS')).create(recursive: true);
      await build(os: 'windows', env: {'APPDATA': appData, 'USERPROFILE': tmp.path});
      await Directory(romDir).create(recursive: true);
      await strategy.restoreSave(game, romPath, Uint8List.fromList([7]), 'Test Monster - White Version [2026].srm');
      expect(File(p.join(romDir, 'Test Monster - White Version.sav')).readAsBytesSync(), [7]);
      expect(Directory(p.join(appData, 'melonDS')).listSync(), isEmpty);
    });

    test('updates the existing save in place (keeps its extension)', () async {
      final f = await put(romDir, 'Test Monster - White Version.srm', [1]);
      await strategy.restoreSave(game, romPath, Uint8List.fromList([5]), 'whatever.sav');
      expect(f.readAsBytesSync(), [5]);
      expect(File(p.join(romDir, 'Test Monster - White Version.sav')).existsSync(), isFalse);
    });

    test('a zip with a .srm is extracted (was skipped before)', () async {
      final zip = ZipEncoder().encode(Archive()
        ..addFile(ArchiveFile('Test Monster - White Version.srm', 2, [4, 4]))
        ..addFile(ArchiveFile('freegosy_sync.txt', 1, [0])));
      await Directory(romDir).create(recursive: true);
      await strategy.restoreSave(game, romPath, Uint8List.fromList(zip), 'save.zip');
      expect(File(p.join(romDir, 'Test Monster - White Version.sav')).readAsBytesSync(), [4, 4]);
    });

    test('a zip with a .sav is extracted', () async {
      final zip = ZipEncoder().encode(Archive()..addFile(ArchiveFile('x.sav', 2, [3, 3])));
      await Directory(romDir).create(recursive: true);
      await strategy.restoreSave(game, romPath, Uint8List.fromList(zip), 'save.zip');
      expect(File(p.join(romDir, 'Test Monster - White Version.sav')).readAsBytesSync(), [3, 3]);
    });

    test('a zip without any save writes nothing and does not fail', () async {
      final zip = ZipEncoder().encode(Archive()..addFile(ArchiveFile('readme.txt', 1, [1])));
      await Directory(romDir).create(recursive: true);
      expect(await strategy.restoreSave(game, romPath, Uint8List.fromList(zip), 'save.zip'), isTrue);
      expect(Directory(romDir).listSync(), isEmpty);
    });

    test('round trip: a pulled save is found again for upload', () async {
      await Directory(romDir).create(recursive: true);
      await strategy.restoreSave(game, romPath, Uint8List.fromList([8]), 'Test Monster - White Version [2026].srm');
      expect(await strategy.getSaveFiles(game, romPath), hasLength(1));
    });
  });

  group('SaveStrategy.saveNameMatchesRom', () {
    test('exact, timestamped and both extensions match', () {
      for (final n in ['Foo.sav', 'foo.SRM', 'Foo [2026-10-01 14-38].srm', 'Foo  [x].sav']) {
        expect(SaveStrategy.saveNameMatchesRom(n, ['Foo']), isTrue, reason: n);
      }
    });
    test('different names, extensions or brackets mid-name do not match', () {
      for (final n in ['Foo2.sav', 'Fo.sav', 'Foo.state', 'Foo [x] Bar.sav', 'Foo.sav.bak', '.sav']) {
        expect(SaveStrategy.saveNameMatchesRom(n, ['Foo']), isFalse, reason: n);
      }
    });
    test('any of several stems may match', () {
      expect(SaveStrategy.saveNameMatchesRom('Bar.sav', ['Foo', 'Bar']), isTrue);
    });
  });
}
