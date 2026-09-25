import 'dart:io' as io;
import 'package:flutter_test/flutter_test.dart';
import 'package:freegosy/core/emulator/strategies/duckstation_strategy.dart';
import 'package:freegosy/core/platform/platform_info.dart';
import 'package:freegosy/core/romm/romm_models.dart';
import 'package:freegosy/core/storage/directory_service.dart';
import 'package:freegosy/core/storage/shared_preferences_app_preferences.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// Answers `findEmulatorExecutable` with a fake exe and records the arguments
/// `launchGameWithHandle` would start the emulator with.
class _CapturingDirectoryService extends DirectoryService {
  _CapturingDirectoryService(super.prefs);

  List<String>? handleArgs;
  String? handleRomPath;

  @override
  Future<String?> findEmulatorExecutable(String emulatorId, String executableName) async =>
      p.join(io.Directory.systemTemp.path, 'duckstation', 'duckstation-qt-x64-ReleaseLTCG.exe');

  @override
  Future<io.Process?> launchGameWithHandle(
      Game game, String romPath, String emulatorId, String exePath,
      {List<String> args = const []}) async {
    handleArgs = args;
    handleRomPath = romPath;
    return null;
  }
}

void main() {
  late _CapturingDirectoryService directoryService;
  late DuckstationStrategy strategy;
  final game = Game(id: 'g1', name: 'Future Racer', platformSlug: 'psx', fileSize: 0);
  final romPath = p.absolute(p.join('roms', 'Future Racer (Europe).chd'));
  final statePath = p.absolute(p.join('savestates', 'SLES-03508_resume.sav'));

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = SharedPreferencesAppPreferences(await SharedPreferences.getInstance());
    directoryService = _CapturingDirectoryService(prefs);
    strategy = DuckstationStrategy(directoryService, platform: const PlatformInfo('windows', environment: {}));
  });

  test('DuckStation can load a state on launch', () {
    expect(strategy.supportsStateLoadOnLaunch, isTrue);
    expect(strategy.stateLoadArgs('/x/y.sav'), ['-statefile', '/x/y.sav']);
  });

  test('a state launch adds -statefile before the ROM', () async {
    await strategy.launchWithHandleAndExtraArgs(game, romPath,
        extraArgs: strategy.stateLoadArgs(statePath));

    expect([...directoryService.handleArgs!, directoryService.handleRomPath!],
        ['-batch', '-fullscreen', '-statefile', statePath, romPath]);
  });

  test('a plain launch passes only the normal arguments', () async {
    await strategy.launchWithHandle(game, romPath);

    expect([...directoryService.handleArgs!, directoryService.handleRomPath!],
        ['-batch', '-fullscreen', romPath]);
  });
}
