import 'dart:io' as io;
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:freegosy/core/emulator/strategies/retroarch_strategy.dart';
import 'package:freegosy/core/platform/platform_info.dart';
import 'package:freegosy/core/romm/romm_models.dart';
import 'package:freegosy/core/save/save_state_info.dart';
import 'package:freegosy/core/save/state_sync_capable.dart';
import 'package:freegosy/core/save/strategies/retroarch_save_strategy.dart';
import 'package:freegosy/core/storage/directory_service.dart';
import 'package:freegosy/core/storage/shared_preferences_app_preferences.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// A DirectoryService that finds no installed emulator, so a test never needs
/// the app's emulators folder.
class _NoEmulatorsDirectoryService extends DirectoryService {
  _NoEmulatorsDirectoryService(super.prefs);

  @override
  Future<String?> findEmulatorExecutable(String emulatorId, String executableName) async => null;
}

void main() {
  late RetroArchSaveStrategy strategy;
  late RetroArchStrategy emulator;
  final game = Game(id: 'g1', name: 'Pokemon Emerald', fsName: 'Pokemon Emerald.gba', platformSlug: 'gba', fileSize: 0);
  final romPath = p.join('roms', 'gba', 'Pokemon Emerald.gba');

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = SharedPreferencesAppPreferences(await SharedPreferences.getInstance());
    final directoryService = DirectoryService(prefs);
    strategy = RetroArchSaveStrategy(directoryService, prefs: prefs);
    emulator = RetroArchStrategy(directoryService);
  });

  test('RetroArchSaveStrategy is StateSyncCapable and RetroArch advertises it', () {
    expect(strategy, isA<StateSyncCapable>());
    expect(emulator.supportsStateSync, isTrue);
    expect(emulator.supportsStateLoadOnLaunch, isTrue);
  });

  test('matcher accepts every slot RetroArch writes for the content', () async {
    final matches = (await strategy.stateFileMatcher(game, romPath))!;

    expect(matches('Pokemon Emerald.state'), isTrue, reason: 'slot 0 has no number');
    expect(matches('Pokemon Emerald.state1'), isTrue);
    expect(matches('Pokemon Emerald.state12'), isTrue);
    expect(matches('Pokemon Emerald.state.auto'), isTrue);
  });

  test('matcher rejects other games, thumbnails, backups and path tricks', () async {
    final matches = (await strategy.stateFileMatcher(game, romPath))!;

    expect(matches('Pokemon Emerald 2.state1'), isFalse, reason: 'another game');
    expect(matches('Pokemon Emerald.state1.png'), isFalse, reason: 'thumbnail');
    expect(matches('Pokemon Emerald.state1.bak'), isFalse, reason: 'Freegosy backup');
    expect(matches('Pokemon Emerald.state1.freegosy_tmp'), isFalse);
    expect(matches('Pokemon Emerald.srm'), isFalse, reason: 'a game save');
    expect(matches('../Pokemon Emerald.state1'), isFalse);
    expect(matches(r'..\Pokemon Emerald.state1'), isFalse);
  });

  test('slots: no number is slot 0, N is slot N, .auto is the auto slot', () {
    expect(strategy.slotOf('Pokemon Emerald.state'), const NumberedStateSlot(0));
    expect(strategy.slotOf('Pokemon Emerald.state3'), const NumberedStateSlot(3));
    expect(strategy.slotOf('Pokemon Emerald.state.auto'), const AutoStateSlot());
    expect(strategy.slotOf('notes.txt'), isA<UnknownStateSlot>());
  });

  test('looksLikeValidState accepts RASTATE and compressed states only', () {
    final raw = Uint8List.fromList([...'RASTATE'.codeUnits, 1, ...List.filled(40, 7)]);
    final rzip = Uint8List.fromList([...'#RZIPv'.codeUnits, 2, 0x23, ...List.filled(40, 7)]);

    expect(strategy.looksLikeValidState(raw), isTrue);
    expect(strategy.looksLikeValidState(rzip), isTrue);
    expect(strategy.looksLikeValidState(Uint8List(0)), isFalse);
    expect(strategy.looksLikeValidState(Uint8List.fromList('<html>502</html>'.codeUnits)), isFalse);
    expect(strategy.looksLikeValidState(Uint8List.fromList('RASTATE'.codeUnits)), isFalse, reason: 'no version byte');
  });

  test('describeState reports the state format and stateScreenshot reads the .png beside it', () async {
    final dir = await io.Directory.systemTemp.createTemp('ra_state_info');
    addTearDown(() => dir.delete(recursive: true));
    final state = io.File(p.join(dir.path, 'Pokemon Emerald.state1'));
    await state.writeAsBytes([...'RASTATE'.codeUnits, 1, ...List.filled(200, 0)]);

    expect((await strategy.describeState(state)).formatId, 'RASTATE v1');
    expect(await strategy.stateScreenshot(state), isNull);

    await io.File('${state.path}.png').writeAsBytes([1, 2, 3]);
    expect(await strategy.stateScreenshot(state), [1, 2, 3]);
  });

  test('RetroArch loads numbered slots with --entryslot and cannot resume the auto slot', () {
    expect(emulator.stateLoadArgs(p.join('states', 'mGBA', 'Pokemon Emerald.state')), ['-e', '0']);
    expect(emulator.stateLoadArgs(p.join('states', 'mGBA', 'Pokemon Emerald.state4')), ['-e', '4']);
    expect(emulator.canLoadState('Pokemon Emerald.state4'), isTrue);
    expect(emulator.canLoadState('Pokemon Emerald.state'), isTrue);
    expect(emulator.canLoadState('Pokemon Emerald.state.auto'), isFalse);
  });

  group('states folder follows retroarch.cfg', () {
    late io.Directory home;

    Future<String> stateDirFor(String cfg) async {
      home = await io.Directory.systemTemp.createTemp('ra_state_cfg');
      addTearDown(() => home.delete(recursive: true));
      final configDir = p.join(home.path, '.config', 'retroarch');
      await io.Directory(configDir).create(recursive: true);
      await io.File(p.join(configDir, 'retroarch.cfg')).writeAsString(cfg.replaceAll('{home}', home.path));
      SharedPreferences.setMockInitialValues({});
      final prefs = SharedPreferencesAppPreferences(await SharedPreferences.getInstance());
      final configured = RetroArchSaveStrategy(_NoEmulatorsDirectoryService(prefs),
          prefs: prefs, platform: PlatformInfo('linux', environment: {'HOME': home.path}));
      return configured.stateDirectory(game, p.join(home.path, 'roms', 'gba', 'Pokemon Emerald.gba'));
    }

    test('savestate_directory with the default per-core folder', () async {
      final dir = await stateDirFor('savestate_directory = "{home}/my_states"\n');
      expect(dir, p.join(home.path, 'my_states', 'mGBA'));
    });

    test('sort_savestates_enable = false drops the core folder', () async {
      final dir = await stateDirFor(
          'savestate_directory = "{home}/my_states"\nsort_savestates_enable = "false"\n');
      expect(dir, p.join(home.path, 'my_states'));
    });

    test('sort_savestates_by_content_enable adds the ROM folder before the core folder', () async {
      final dir = await stateDirFor(
          'savestate_directory = "{home}/my_states"\nsort_savestates_by_content_enable = "true"\n');
      expect(dir, p.join(home.path, 'my_states', 'gba', 'mGBA'));
    });

    test('savestates_in_content_dir puts states next to the ROM', () async {
      final dir = await stateDirFor('savestates_in_content_dir = "true"\n');
      expect(dir, p.join(home.path, 'roms', 'gba'));
    });
  });
}
