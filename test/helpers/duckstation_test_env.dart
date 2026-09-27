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
