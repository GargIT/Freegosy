import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:freegosy/core/platform/platform_info.dart';
import 'package:freegosy/core/romm/romm_models.dart';
import 'package:freegosy/core/save/strategies/retroarch_save_strategy.dart';
import 'package:mockito/mockito.dart';
import 'package:path/path.dart' as p;

import 'save_sync_regression_test.mocks.dart';

/// Issue #79: RetroArch installed by EmuDeck for Windows, in
/// `%USERPROFILE%\EmuDeck\Emulators\RetroArch`, with its saves directly in
/// its `saves` folder (no core folders). Freegosy said "No Saves Found".
void main() {
  late Directory tempDir;
  late String home;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('ra_emudeck_win_');
    home = p.join(tempDir.path, 'home');
    await Directory(p.join(home, 'AppData', 'Roaming')).create(recursive: true);
  });

  tearDown(() => tempDir.delete(recursive: true));

  RetroArchSaveStrategy strategyWith({String? retroArchDir}) {
    final dirService = MockDirectoryService();
    when(dirService.findEmulatorExecutable(argThat(isA<String>()), argThat(isA<String>())))
        .thenAnswer((_) async => retroArchDir);
    when(dirService.linuxSyncPreset).thenReturn('default');
    return RetroArchSaveStrategy(dirService,
        platform: PlatformInfo('windows',
            environment: {'APPDATA': p.join(home, 'AppData', 'Roaming'), 'USERPROFILE': home}));
  }

  Game psx(String rom) => Game(id: '1', name: rom, fsName: rom, platformSlug: 'psx', fileSize: 0);

  test('EmuDeck\'s RetroArch in %USERPROFILE%\\EmuDeck\\Emulators is found without a path set', () async {
    final saves = Directory(p.join(home, 'EmuDeck', 'Emulators', 'RetroArch', 'saves'))..createSync(recursive: true);
    File(p.join(saves.path, 'Crash Bandicoot (USA).srm')).writeAsBytesSync([1]);

    final strategy = strategyWith();
    final g = psx('Crash Bandicoot (USA).cue');
    expect(await strategy.getSaveDir(g, p.join(tempDir.path, 'roms', g.fsName!)), saves.path);
  });

  test('a save directly in the save folder is found when core folders are assumed', () async {
    // No retroarch.cfg to read, so "Sort Saves into Folders by Core" is
    // assumed on (RetroArch's default), but the saves are flat.
    final ra = p.join(tempDir.path, 'RetroArch');
    final saves = Directory(p.join(ra, 'saves'))..createSync(recursive: true);
    Directory(p.join(saves.path, 'mame')).createSync();
    File(p.join(saves.path, 'Spyro the Dragon (USA).srm')).writeAsBytesSync([1]);

    final strategy = strategyWith(retroArchDir: ra);
    final g = psx('Spyro the Dragon (USA).cue');
    expect(await strategy.getSaveDir(g, p.join(tempDir.path, 'roms', g.fsName!)), saves.path);
  });
}
