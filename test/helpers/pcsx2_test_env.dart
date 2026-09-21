import 'dart:io';
import 'package:freegosy/core/platform/platform_info.dart';
import 'package:freegosy/core/save/strategies/pcsx2_save_strategy.dart';
import 'package:freegosy/core/storage/directory_service.dart';
import 'package:freegosy/core/storage/shared_preferences_app_preferences.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// Minimal DirectoryService stub — answers only what Pcsx2SaveStrategy asks
/// while resolving its save root.
class _StubDirectoryService extends DirectoryService {
  _StubDirectoryService(super.prefs, {required this.exePath});

  final String exePath;

  @override
  Future<String?> findEmulatorExecutable(String emulatorId, String executableName) async => exePath;

  @override
  Future<String> getEmulatorAppSupportDirectory(String emulatorName, {String? platformSlug}) async => '';
}

/// A portable PCSX2 install under `<base>/pcsx2` (`pcsx2-qt.exe` + `memcards/`)
/// plus a Pcsx2SaveStrategy wired to it.
class Pcsx2TestEnv {
  Pcsx2TestEnv._(this.exeDir, this.directoryService, this.strategy, this.prefs);

  final String exeDir;

  /// The stub the strategy resolves its save root through; hand it to other
  /// services that must resolve the same PCSX2 install.
  final DirectoryService directoryService;
  final Pcsx2SaveStrategy strategy;
  final SharedPreferencesAppPreferences prefs;

  String get statesDir => p.join(exeDir, 'sstates');

  static Future<Pcsx2TestEnv> create(Directory base) async {
    final exeDir = p.join(base.path, 'pcsx2');
    await Directory(p.join(exeDir, 'memcards')).create(recursive: true);
    final fakeExe = p.join(exeDir, 'pcsx2-qt.exe');
    await File(fakeExe).writeAsString('');

    SharedPreferences.setMockInitialValues({});
    final prefs = SharedPreferencesAppPreferences(await SharedPreferences.getInstance());
    final directoryService = _StubDirectoryService(prefs, exePath: fakeExe);
    final strategy = Pcsx2SaveStrategy(
      directoryService,
      prefs,
      platform: const PlatformInfo('windows', environment: {}),
    );
    return Pcsx2TestEnv._(exeDir, directoryService, strategy, prefs);
  }
}
