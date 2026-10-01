import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:freegosy/core/platform/platform_info.dart';
import 'package:freegosy/core/romm/romm_models.dart';
import 'package:freegosy/core/save/strategies/retroarch_save_strategy.dart';
import 'package:mockito/mockito.dart';
import 'package:path/path.dart' as p;

import 'save_sync_regression_test.mocks.dart';

/// A web-player save named "<game> [timestamp].srm" must land as the ROM's
/// `<rom>.srm`, which is what a RetroArch core opens (issue #24).
void main() {
  late Directory tempDir;
  late String saveDir;
  late RetroArchSaveStrategy strategy;

  const romName = 'Test Monster - White Version (USA)';

  Game game({String slug = 'nds'}) =>
      Game(id: '1', name: 'Test Monster - White Version', fsName: '$romName.nds', platformSlug: slug, fileSize: 0);

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('ra_ps1_card_');
    final configDir = p.join(tempDir.path, '.config', 'retroarch');
    await Directory(configDir).create(recursive: true);
    saveDir = p.join(tempDir.path, 'saves');
    await File(p.join(configDir, 'retroarch.cfg')).writeAsString([
      'savefile_directory = "$saveDir"',
      'sort_savefiles_enable = "false"',
    ].join('\n'));
    await Directory(saveDir).create(recursive: true);

    final dirService = MockDirectoryService();
    when(dirService.findEmulatorExecutable(argThat(isA<String>()), argThat(isA<String>())))
        .thenAnswer((_) async => null);
    when(dirService.linuxSyncPreset).thenReturn('default');
    when(dirService.getEmulatorAppSupportDirectory('retroarch', platformSlug: anyNamed('platformSlug')))
        .thenAnswer((_) async => configDir);
    strategy = RetroArchSaveStrategy(dirService, platform: PlatformInfo('linux', environment: {'HOME': tempDir.path}));
  });

  tearDown(() => tempDir.delete(recursive: true));

  String romPath() => p.join(tempDir.path, 'roms', '$romName.nds');
  List<String> savesOnDisk() =>
      Directory(saveDir).listSync().whereType<File>().map((f) => p.basename(f.path)).toList()..sort();

  final bytes = Uint8List.fromList([1, 2, 3]);

  test('a web player timestamped .srm is restored as <rom>.srm', () async {
    expect(await strategy.restoreSave(game(), romPath(), bytes, 'Test Monster - White Version [2026-10-01 14-38-41-643].srm'), isTrue);
    expect(savesOnDisk(), ['$romName.srm']);
  });

  test('a timestamped .sav is restored as <rom>.srm too', () async {
    await strategy.restoreSave(game(), romPath(), bytes, 'Test Monster - White Version [2026].sav');
    expect(savesOnDisk(), ['$romName.srm']);
  });

  test('a plain <name>.sav still becomes .srm', () async {
    await strategy.restoreSave(game(), romPath(), bytes, 'Other.sav');
    expect(savesOnDisk(), ['Other.srm']);
  });

  test('a plain .srm keeps its name', () async {
    await strategy.restoreSave(game(), romPath(), bytes, 'Other.srm');
    expect(savesOnDisk(), ['Other.srm']);
  });
}
