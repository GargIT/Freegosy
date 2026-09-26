import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:freegosy/core/save/strategies/duckstation_config.dart';
import 'package:path/path.dart' as p;

void main() {
  group('DuckstationMemcardConfig', () {
    test('reads card types, paths, directory and playlist title from [MemoryCards]', () {
      final config = DuckstationMemcardConfig.fromIni('''
[Main]
Card1Type = PerGame
[MemoryCards]
Card1Type = Shared
Card1Path = my_card.mcd
Card2Type = PerGameFileTitle
Directory = D:\\cards
UsePlaylistTitle = false
[Other]
Card2Type = None
''');

      expect(config.typeOf(1), DuckstationCardType.shared, reason: 'only [MemoryCards] counts');
      expect(config.typeOf(2), DuckstationCardType.perGameFileTitle);
      expect(config.cardPaths[1], 'my_card.mcd');
      expect(config.directory, r'D:\cards');
      expect(config.usePlaylistTitle, isFalse);
    });

    test('defaults: port 1 per game by title, other ports none, playlist title on', () {
      final config = DuckstationMemcardConfig.fromIni(null);

      expect(config.typeOf(1), DuckstationCardType.perGameTitle);
      expect(config.typeOf(2), DuckstationCardType.none);
      expect(config.typeOf(8), DuckstationCardType.none);
      expect(config.directory, isNull);
      expect(config.usePlaylistTitle, isTrue);
    });

    test('the game\'s own settings override the global ones key by key', () {
      final config = DuckstationMemcardConfig.fromIni(
        '[MemoryCards]\nCard1Type = Shared\nCard2Type = PerGame\n',
        '[MemoryCards]\r\nCard1Type = PerGame\r\n',
      );

      expect(config.typeOf(1), DuckstationCardType.perGameSerial);
      expect(config.typeOf(2), DuckstationCardType.perGameSerial, reason: 'not overridden');
    });

    test('an unknown type falls back to the default', () {
      final config = DuckstationMemcardConfig.fromIni('[MemoryCards]\nCard1Type = Bogus\n');

      expect(config.typeOf(1), DuckstationCardType.perGameTitle);
    });

    test('every DuckStation type name is understood', () {
      for (final type in DuckstationCardType.values) {
        final config = DuckstationMemcardConfig.fromIni('[MemoryCards]\nCard1Type = ${type.iniValue}\n');
        expect(config.typeOf(1), type);
      }
      expect(DuckstationCardType.values.where((t) => t.isPerGame), [
        DuckstationCardType.perGameSerial,
        DuckstationCardType.perGameTitle,
        DuckstationCardType.perGameFileTitle,
      ]);
    });
  });

  test('duckstationSafeFileName replaces characters Windows forbids', () {
    expect(duckstationSafeFileName('Colin McRae Rally 2.0 (Europe) (En,Fr,De,Es,It)'),
        'Colin McRae Rally 2.0 (Europe) (En,Fr,De,Es,It)');
    expect(duckstationSafeFileName('A: B/C\\D?*"<>|'), 'A_ B_C_D______');
  });

  group('DuckstationGameDb', () {
    const gamedb = '''
SLES-02604:
  name: "Colin McRae Rally 2.0"
  compatibility:
    rating: NoIssues
SLES-02605:
  name: "Colin McRae Rally 2.0"
  saveName: "Colin McRae Rally 2.0 (Europe) (En,Fr,De,Es,It)"
  metadata:
    publisher: "Codemasters"
    name: "not a title"
SLUS-00001:
  name: 'It''s a game'
SCUS-94163:
  name: "Final Fantasy VII"
  saveName: "Final Fantasy VII (USA) (Disc 1)"
''';
    const discsets = '''
- name: "Final Fantasy VII"
  localizedName: "FF7"
  saveName: "Final Fantasy VII (USA)"
  serials:
    - SCUS-94163
    - SCUS-94164
    - SCUS-94165
- name: "No Save Name Set"
  serials:
    - SLPS-00001
''';

    test('parseGameDb: saveName, else name; nested keys ignored; quotes unescaped', () {
      final titles = DuckstationGameDb.parseGameDb(gamedb);

      expect(titles['SLES-02605'], 'Colin McRae Rally 2.0 (Europe) (En,Fr,De,Es,It)');
      expect(titles['SLES-02604'], 'Colin McRae Rally 2.0');
      expect(titles['SLUS-00001'], "It's a game");
      expect(titles['SCUS-94163'], 'Final Fantasy VII (USA) (Disc 1)');
    });

    test('parseDiscSets maps every serial of a set to its saveName, else name', () {
      final titles = DuckstationGameDb.parseDiscSets(discsets);

      expect(titles['SCUS-94163'], 'Final Fantasy VII (USA)');
      expect(titles['SCUS-94165'], 'Final Fantasy VII (USA)');
      expect(titles['SLPS-00001'], 'No Save Name Set');
    });

    group('saveTitle', () {
      late Directory dir;
      setUp(() async {
        DuckstationGameDb.clearCache();
        dir = await Directory.systemTemp.createTemp('duckstation_gamedb');
        await File(p.join(dir.path, 'gamedb.yaml')).writeAsString(gamedb);
        await File(p.join(dir.path, 'discsets.yaml')).writeAsString(discsets);
      });
      tearDown(() => dir.delete(recursive: true));

      test('uses the disc set title for a multi-disc game only with playlist titles on', () async {
        expect(await DuckstationGameDb.saveTitle(dir.path, 'SCUS-94163', usePlaylistTitle: true),
            'Final Fantasy VII (USA)');
        expect(await DuckstationGameDb.saveTitle(dir.path, 'scus-94163', usePlaylistTitle: false),
            'Final Fantasy VII (USA) (Disc 1)');
      });

      test('a single-disc game uses its own entry', () async {
        expect(await DuckstationGameDb.saveTitle(dir.path, 'SLES-02605', usePlaylistTitle: true),
            'Colin McRae Rally 2.0 (Europe) (En,Fr,De,Es,It)');
      });

      test('null for an unknown serial or a missing database', () async {
        expect(await DuckstationGameDb.saveTitle(dir.path, 'SLUS-99999', usePlaylistTitle: true), isNull);
        expect(
            await DuckstationGameDb.saveTitle(p.join(dir.path, 'nope'), 'SLES-02605', usePlaylistTitle: true),
            isNull);
      });

      test('re-reads the database when it changes', () async {
        expect(await DuckstationGameDb.saveTitle(dir.path, 'SLES-02604', usePlaylistTitle: true),
            'Colin McRae Rally 2.0');
        final file = File(p.join(dir.path, 'gamedb.yaml'));
        await file.writeAsString('SLES-02604:\n  name: "Renamed"\n');
        await file.setLastModified(DateTime.now().add(const Duration(minutes: 1)));

        expect(await DuckstationGameDb.saveTitle(dir.path, 'SLES-02604', usePlaylistTitle: true), 'Renamed');
      });
    });
  });
}
