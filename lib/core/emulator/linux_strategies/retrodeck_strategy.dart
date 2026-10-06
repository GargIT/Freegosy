import 'dart:io' as io;
import 'package:path/path.dart' as p;
import 'package:freegosy/core/romm/romm_models.dart';
import 'linux_environment_strategy.dart';

class RetroDeckStrategy extends LinuxEnvironmentStrategy {
  @override
  String get name => 'RetroDECK';

  @override
  String get id => 'retrodeck';

  @override
  String getRomsRoot(String home, String? customPath, String? emudeckRoot) {
    if (customPath != null) return customPath;
    if (emudeckRoot != null) return p.join(emudeckRoot, 'roms');
    return p.join(home, 'retrodeck', 'roms');
  }

  @override
  String getEmulatorsRoot(String home, String? customPath, String? emudeckRoot) {
    if (customPath != null) return customPath;
    if (emudeckRoot != null) return p.join(emudeckRoot, 'tools');
    return p.join(home, 'retrodeck', 'tools');
  }

  @override
  String getEmulatorAppSupportDirectory(String home, String emulatorName, String? emudeckRoot, {String? platformSlug}) {
    final base = p.join(home, '.var', 'app', 'net.retrodeck.retrodeck', 'config');
    
    final Map<String, String> retrodeckMap = {
      'pcsx2': 'PCSX2',
      'dolphin': 'dolphin-emu',
      'ppsspp': 'ppsspp',
      'retroarch': 'retroarch',
    };

    final folderName = retrodeckMap[emulatorName.toLowerCase()] ?? emulatorName;
    final emuPath = p.join(base, folderName);
    
    // Most emulators in RetroDECK (Flatpak) use a 'saves' subfolder
    final savesPath = p.join(emuPath, 'saves');
    if (io.Directory(savesPath).existsSync()) {
      return savesPath;
    }
    
    return emuPath;
  }

  @override
  String getBiosPath(String home, String? emudeckRoot) {
    if (emudeckRoot != null) return p.join(emudeckRoot, 'bios');
    return p.join(home, '.var', 'app', 'net.retrodeck.retrodeck', 'config', 'bios');
  }

  @override
  Future<String?> findExecutable(String emulatorId, String executableName, String emulatorsRoot, String? emudeckRoot) async {
    // RetroDECK uses a single flatpak command for all emulators
    return 'retrodeck-flatpak';
  }

  /// `flatpak run net.retrodeck.retrodeck [romPath]`, with `flatpak` found
  /// by [resolveFlatpak] rather than in the inherited PATH, which lacks
  /// `/usr/bin` in some sessions (#84).
  static (String, List<String>) command(String? romPath,
          {String Function() resolveFlatpak = LinuxEnvironmentStrategy.resolveFlatpakExecutable}) =>
      (resolveFlatpak(), ['run', 'net.retrodeck.retrodeck', ?romPath]);

  @override
  Future<void> launch(Game game, String romPath, String emulatorId, String exePath, {List<String> args = const []}) async {
    final (exe, cmdArgs) = command(romPath);
    await io.Process.start(exe, cmdArgs, mode: io.ProcessStartMode.detached);
  }

  @override
  Future<io.Process?> launchWithHandle(Game game, String romPath, String emulatorId, String exePath, {List<String> args = const []}) async {
    final (exe, cmdArgs) = command(romPath);
    return await io.Process.start(exe, cmdArgs, mode: io.ProcessStartMode.normal);
  }

  @override
  Future<void> launchStandalone(String emulatorId, String exePath, {List<String> args = const []}) async {
    final (exe, cmdArgs) = command(null);
    await io.Process.start(exe, cmdArgs, mode: io.ProcessStartMode.detached);
  }
}