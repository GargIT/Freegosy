import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:freegosy/core/platform/platform_info.dart';
import 'package:freegosy/core/romm/romm_models.dart';
import 'package:freegosy/core/save/strategies/retroarch_save_strategy.dart';
import 'package:mockito/mockito.dart';
import 'package:path/path.dart' as p;

import 'save_sync_regression_test.mocks.dart';

/// With "Sort Saves into Folders by Core" on, RetroArch keeps a core's saves
/// in a folder named after the core's library_name. A game's save must go
/// to its own core's folder, never to another core's.
///
/// Seen on a real install: PS2 memory cards restored for RetroArch landed in
/// `saves/Mupen64Plus-Next/`, the N64 core's folder, because the PS2 entry
/// named a `PCSX2` folder that doesn't exist and the fallback then picked the
/// most recently modified core folder.
void main() {
  late Directory tempDir;
  late String saveRoot;
  late RetroArchSaveStrategy strategy;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('ra_core_folder_');
    saveRoot = p.join(tempDir.path, 'saves');
    final configDir = p.join(tempDir.path, 'RetroArch');
    await Directory(configDir).create(recursive: true);
    await File(p.join(configDir, 'retroarch.cfg')).writeAsString([
      'savefile_directory = "$saveRoot"',
      'sort_savefiles_enable = "true"',
    ].join('\n'));
    await Directory(saveRoot).create(recursive: true);

    final dirService = MockDirectoryService();
    when(dirService.findEmulatorExecutable(argThat(isA<String>()), argThat(isA<String>())))
        .thenAnswer((_) async => null);
    when(dirService.linuxSyncPreset).thenReturn('default');
    strategy = RetroArchSaveStrategy(dirService,
        platform: PlatformInfo('windows', environment: {'APPDATA': tempDir.path, 'USERPROFILE': tempDir.path}));
  });

  tearDown(() => tempDir.delete(recursive: true));

  Game game(String slug, String rom) => Game(id: '1', name: rom, fsName: rom, platformSlug: slug, fileSize: 0);
  String romPath(String rom) => p.join(tempDir.path, 'roms', rom);

  test('coreIdFor: the core as RomM\'s player and Argosy name it', () {
    expect(strategy.coreIdFor(game('gba', 'x.gba')), 'mgba');
    expect(strategy.coreIdFor(game('psx', 'x.cue')), 'pcsx_rearmed');
    expect(strategy.coreIdFor(game('n64', 'x.z64')), 'mupen64plus_next');
    expect(strategy.coreIdFor(game('nds', 'x.nds')), 'melonds');
    expect(strategy.coreIdFor(game('unknown-platform', 'x.bin')), isNull);
    // RomM's slugs for systems Freegosy knows by another name.
    expect(strategy.coreIdFor(game('famicom', 'x.nes')), strategy.coreIdFor(game('nes', 'x.nes')));
    expect(strategy.coreIdFor(game('neo-geo-pocket-color', 'x.ngc')), 'mednafen_ngp');

    strategy.setLaunchCoreOverride('mednafen_psx_hw_libretro.dll');
    expect(strategy.coreIdFor(game('psx', 'x.cue')), 'mednafen_psx_hw', reason: 'the core the game was launched with');
  });

  test('a first save goes to the core\'s own folder, not the most recently modified one', () async {
    final n64 = Directory(p.join(saveRoot, 'Mupen64Plus-Next'))..createSync();
    File(p.join(n64.path, 'Wipeout 64 (Europe).srm')).writeAsBytesSync([1]);

    final ps2 = game('ps2', 'Burnout 3 - Takedown (USA).iso');
    expect(await strategy.getSaveDir(ps2, romPath(ps2.fsName!)), p.join(saveRoot, 'LRPS2'));

    expect(await strategy.restoreSave(ps2, romPath(ps2.fsName!), Uint8List.fromList([1, 2, 3]), 'Mcd001.ps2'), isTrue);
    expect(File(p.join(saveRoot, 'LRPS2', 'Mcd001.ps2')).existsSync(), isTrue);
    expect(n64.listSync().map((e) => p.basename(e.path)), ['Wipeout 64 (Europe).srm']);
  });

  test('folders are named after each core\'s library_name', () async {
    const expected = {
      'n64': 'Mupen64Plus-Next',
      'nes': 'FCEUmm',
      'ps2': 'LRPS2',
      'psx': 'PCSX-ReARMed',
      'nds': 'melonDS',
      'megadrive': 'Genesis Plus GX',
      'saturn': 'Beetle Saturn',
      'dreamcast': 'Flycast',
      'lynx': 'Beetle Lynx',
      'dos': 'DOSBox-pure',
      'amiga': 'PUAE',
    };
    for (final MapEntry(key: slug, value: folder) in expected.entries) {
      final g = game(slug, 'Some Game.bin');
      expect(await strategy.getSaveDir(g, romPath('Some Game.bin')), p.join(saveRoot, folder), reason: slug);
    }
  });

  test('an existing core folder is used as before', () async {
    Directory(p.join(saveRoot, 'PCSX-ReARMed')).createSync();
    Directory(p.join(saveRoot, 'Mupen64Plus-Next')).createSync();
    final g = game('psx', 'Crash Bandicoot (Europe).cue');
    expect(await strategy.getSaveDir(g, romPath(g.fsName!)), p.join(saveRoot, 'PCSX-ReARMed'));
  });

  test('a save already in another core\'s folder for this game is still found', () async {
    // The ROM-name scan is unchanged: a game played with a different core
    // keeps its save in that core's folder.
    final beetle = Directory(p.join(saveRoot, 'Beetle PSX HW'))..createSync();
    File(p.join(beetle.path, 'Crash Bandicoot (Europe).srm')).writeAsBytesSync([1]);
    final g = game('psx', 'Crash Bandicoot (Europe).cue');
    expect(await strategy.getSaveDir(g, romPath(g.fsName!)), beetle.path);
  });
}
