import 'dart:io';
import 'package:freegosy/core/platform/platform_info.dart';
import 'package:freegosy/core/save/strategies/duckstation_save_strategy.dart';
import 'package:freegosy/core/save/strategies/duckstation_state_file.dart';
import 'package:freegosy/core/storage/directory_service.dart';
import 'package:freegosy/core/storage/shared_preferences_app_preferences.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// Minimal DirectoryService stub — answers only what DuckstationSaveStrategy
/// asks while resolving its data folder.
class _StubDirectoryService extends DirectoryService {
  _StubDirectoryService(super.prefs, {required this.exePath});

  final String exePath;

  @override
  Future<String?> findEmulatorExecutable(String emulatorId, String executableName) async => exePath;

  @override
  Future<String> getEmulatorAppSupportDirectory(String emulatorName, {String? platformSlug}) async => '';
}

/// A portable DuckStation install under `<base>/duckstation` (the exe,
/// `portable.txt` and `memcards/`) plus a DuckstationSaveStrategy wired to it.
class DuckstationTestEnv {
  DuckstationTestEnv._(this.exeDir, this.directoryService, this.strategy);

  final String exeDir;
  final DirectoryService directoryService;
  final DuckstationSaveStrategy strategy;

  String get statesDir => p.join(exeDir, 'savestates');
  String get memcardsDir => p.join(exeDir, 'memcards');

  /// Writes DuckStation's `settings.ini` (e.g. its `[MemoryCards]` section).
  Future<void> writeSettings(String ini) => File(p.join(exeDir, 'settings.ini')).writeAsString(ini);

  /// Writes `gamesettings/<serial>.ini`, DuckStation's per-game overrides.
  Future<void> writeGameSettings(String serial, String ini) async {
    final file = File(p.join(exeDir, 'gamesettings', '$serial.ini'));
    await file.parent.create(recursive: true);
    await file.writeAsString(ini);
  }

  /// Writes DuckStation's `resources/gamedb.yaml` (and `discsets.yaml`).
  Future<void> writeGameDb(String gamedb, {String discsets = ''}) async {
    final dir = Directory(p.join(exeDir, 'resources'));
    await dir.create(recursive: true);
    await File(p.join(dir.path, 'gamedb.yaml')).writeAsString(gamedb);
    await File(p.join(dir.path, 'discsets.yaml')).writeAsString(discsets);
  }

  /// Writes a 128 KB memory card named [name] in the memory card folder.
  Future<File> writeCard(String name, {int fill = 1}) async {
    final file = File(p.join(memcardsDir, name));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(List.filled(128 * 1024, fill));
    return file;
  }

  static Future<DuckstationTestEnv> create(Directory base, {ZstdDecompressor? zstd}) async {
    final exeDir = p.join(base.path, 'duckstation');
    await Directory(p.join(exeDir, 'memcards')).create(recursive: true);
    await File(p.join(exeDir, 'portable.txt')).writeAsString('');
    final fakeExe = p.join(exeDir, 'duckstation-qt-x64-ReleaseLTCG.exe');
    await File(fakeExe).writeAsString('');

    SharedPreferences.setMockInitialValues({});
    final prefs = SharedPreferencesAppPreferences(await SharedPreferences.getInstance());
    final directoryService = _StubDirectoryService(prefs, exePath: fakeExe);
    final strategy = DuckstationSaveStrategy(
      directoryService,
      prefs,
      platform: const PlatformInfo('windows', environment: {}),
      zstd: zstd,
    );
    return DuckstationTestEnv._(exeDir, directoryService, strategy);
  }
}
