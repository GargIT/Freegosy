import 'dart:io' as io;
import 'package:flutter_test/flutter_test.dart';
import 'package:freegosy/core/emulator/strategies/pcsx2_strategy.dart';
import 'package:freegosy/core/platform/platform_info.dart';
import 'package:freegosy/core/romm/romm_models.dart';
import 'package:freegosy/core/storage/directory_service.dart';
import 'package:freegosy/core/storage/shared_preferences_app_preferences.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// Answers `findEmulatorExecutable` with a fake exe and records the arguments
/// `launchGameWithHandle` / `launchGame` would start the emulator with.
class _CapturingDirectoryService extends DirectoryService {
  _CapturingDirectoryService(super.prefs);

  List<String>? handleArgs;
  String? handleRomPath;
  List<String>? plainArgs;

  @override
  Future<String?> findEmulatorExecutable(String emulatorId, String executableName) async =>
      p.join(io.Directory.systemTemp.path, 'pcsx2', 'pcsx2-qt.exe');

  @override
  Future<io.Process?> launchGameWithHandle(
      Game game, String romPath, String emulatorId, String exePath,
      {List<String> args = const []}) async {
    handleArgs = args;
    handleRomPath = romPath;
    return null;
  }

  @override
  Future<void> launchGame(Game game, String romPath, String emulatorId, String exePath,
      {List<String> args = const []}) async {
    plainArgs = args;
  }
}

void main() {
  late _CapturingDirectoryService directoryService;
  late Pcsx2Strategy strategy;
  final game = Game(id: 'g1', name: 'Ico (SCUS-97113)', platformSlug: 'ps2', fileSize: 0);
  final romPath = p.absolute(p.join('roms', 'Ico (SCUS-97113).iso'));
  final statePath = p.absolute(p.join('sstates', 'SCUS-97113 (A1B2C3D4).resume.p2s'));

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = SharedPreferencesAppPreferences(await SharedPreferences.getInstance());
    directoryService = _CapturingDirectoryService(prefs);
    strategy = Pcsx2Strategy(directoryService, platform: const PlatformInfo('windows', environment: {}));
  });

  test('PCSX2 supports auto-loading a state', () {
    expect(strategy.supportsStateAutoLoad, isTrue);
    expect(strategy.stateLoadArgs('/x/y.p2s'), ['-statefile', '/x/y.p2s']);
  });

  test('launchWithHandleAndExtraArgs adds the extra arguments before the ROM', () async {
    await strategy.launchWithHandleAndExtraArgs(game, romPath,
        extraArgs: strategy.stateLoadArgs(statePath));

    expect([...directoryService.handleArgs!, directoryService.handleRomPath!],
        ['-batch', '-fullscreen', '-statefile', statePath, romPath]);
  });

  test('launchWithHandle passes only the normal arguments', () async {
    await strategy.launchWithHandle(game, romPath);

    expect([...directoryService.handleArgs!, directoryService.handleRomPath!],
        ['-batch', '-fullscreen', romPath]);
  });

  test('launchWithExtraArgs adds the extra arguments', () async {
    await strategy.launchWithExtraArgs(game, romPath,
        extraArgs: strategy.stateLoadArgs(statePath));

    expect(directoryService.plainArgs, ['-batch', '-fullscreen', '-statefile', statePath]);
  });

  test('launch passes only the normal arguments', () async {
    await strategy.launch(game, romPath);

    expect(directoryService.plainArgs, ['-batch', '-fullscreen']);
  });

  test('a launch with extra arguments leaves nothing behind for the next plain launch', () async {
    await strategy.launchWithHandleAndExtraArgs(game, romPath,
        extraArgs: strategy.stateLoadArgs(statePath));
    await strategy.launchWithExtraArgs(game, romPath,
        extraArgs: strategy.stateLoadArgs(statePath));

    await strategy.launchWithHandle(game, romPath);
    await strategy.launch(game, romPath);

    expect(directoryService.handleArgs, ['-batch', '-fullscreen']);
    expect(directoryService.plainArgs, ['-batch', '-fullscreen']);
  });
}
