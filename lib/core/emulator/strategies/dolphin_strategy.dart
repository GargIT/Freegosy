import 'dart:io' as io;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:freegosy/core/emulator/emulator_strategy.dart';
import 'package:freegosy/core/platform/platform_info.dart';
import 'package:freegosy/core/retroachievements/retroachievements_emulator_login.dart';
import 'package:freegosy/core/romm/romm_models.dart';
import 'package:freegosy/core/storage/directory_service.dart';
import 'package:freegosy/core/storage/ini_file.dart';

class DolphinStrategy extends EmulatorStrategy {
  final DirectoryService _directoryService;
  final Future<RetroAchievementsEmulatorLogin?> Function()? _raLoginLoader;

  DolphinStrategy(
    this._directoryService, {
    super.platform,
    Future<RetroAchievementsEmulatorLogin?> Function()? raLoginLoader,
  }) : _raLoginLoader = raLoginLoader;

  @override
  DirectoryService get directoryService => _directoryService;

  @override
  List<String> get launchArgs => platform.isLinux ? <String>[] : ['-b', '-e'];

  @override
  String get name => 'Dolphin';

  @override
  String get emulatorId => 'dolphin';

  @override
  List<String> get supportedSlugs => ['gc', 'gamecube', 'wii', 'ngc'];

  @override
  String get windowsExecutable => 'Dolphin.exe';

  @override
  String get linuxExecutable => 'Dolphin.AppImage';

  @override
  String get macosExecutable => 'Dolphin.app/Contents/MacOS/Dolphin';

  @override
  bool get supportsSaveSync => true;

  @override
  bool get supportsRetroAchievementsLogin => true;

  @override
  String resolveSavePath(Game game) {
    return ''; // Placeholder
  }

  // ── RetroAchievements ────────────────────────────────────────

  static const _raSection = 'Achievements';

  /// Dolphin keeps its RetroAchievements settings in `RetroAchievements.ini`,
  /// beside `Dolphin.ini`.
  static const _raFileName = 'RetroAchievements.ini';

  /// The folders that may hold Dolphin's config files, most likely first: a
  /// portable install's `User/Config` beside the executable, the Flatpak's,
  /// the legacy `~/.dolphin-emu/Config`, the XDG `~/.config/dolphin-emu`,
  /// Windows' `Documents` and `%APPDATA%` folders, and macOS' Application
  /// Support.
  @visibleForTesting
  Future<List<String>> candidateConfigDirectories() async {
    final home = platform.environment['HOME'] ?? '';
    final exe = await findExecutable();
    final result = <String>[];
    if (exe != null && !exe.startsWith('flatpak ') && !exe.toLowerCase().endsWith('.appimage')) {
      result.add(p.join(io.File(exe).parent.path, 'User', 'Config'));
    }
    if (platform.isWindows) {
      final profile = platform.environment['USERPROFILE'];
      final appData = platform.environment['APPDATA'];
      if (profile != null && profile.isNotEmpty) result.add(p.join(profile, 'Documents', 'Dolphin Emulator', 'Config'));
      if (appData != null && appData.isNotEmpty) result.add(p.join(appData, 'Dolphin Emulator', 'Config'));
    } else if (platform.isMacOS) {
      if (home.isNotEmpty) result.add(p.join(home, 'Library', 'Application Support', 'Dolphin', 'Config'));
    } else if (platform.isLinux && home.isNotEmpty) {
      final xdg = platform.environment['XDG_CONFIG_HOME'];
      result
        ..add(p.join(home, '.var', 'app', 'org.DolphinEmu.dolphin-emu', 'config', 'dolphin-emu'))
        ..add(p.join(home, '.dolphin-emu', 'Config'))
        ..add(p.join(xdg != null && xdg.isNotEmpty ? xdg : p.join(home, '.config'), 'dolphin-emu'));
    }
    return result;
  }

  /// The first candidate folder where Dolphin has already made its
  /// Dolphin.ini, or null (Dolphin has not run yet, or its folder isn't one
  /// we know).
  Future<String?> _configDirectory() async {
    for (final dir in await candidateConfigDirectories()) {
      if (await io.File(p.join(dir, 'Dolphin.ini')).exists()) return dir;
    }
    return null;
  }

  /// Signs Dolphin in before it starts. Never fails a launch.
  @override
  Future<void> preLaunch(Game game, String romPath) async {
    try {
      final login = await (_raLoginLoader ?? () => RetroAchievementsEmulatorLogin.load(_directoryService.prefs))();
      if (login != null) await applyRetroAchievementsLogin(login);
    } catch (e) {
      debugPrint('[Dolphin] Skipping RetroAchievements login: $e');
    }
  }

  /// Dolphin has no safe command-line route for this (its `-C` option would
  /// put the token on the process list), so the login goes into
  /// `RetroAchievements.ini`: `Enabled`, `Username`, `ApiToken` and
  /// `HardcoreEnabled` (off unless turned on in Settings) in `[Achievements]`.
  /// The file is owner-readable only, other lines are left alone, and nothing
  /// is written before Dolphin has run once (no Dolphin.ini).
  @override
  Future<void> applyRetroAchievementsLogin(RetroAchievementsEmulatorLogin login) async {
    try {
      final dir = await _configDirectory();
      if (dir == null) {
        debugPrint('[Dolphin] RetroAchievements login not applied: no Dolphin.ini found (has Dolphin been run?)');
        return;
      }
      await updateIniFile(io.File(p.join(dir, _raFileName)), (config) {
        var changed = false;
        changed |= config.set(_raSection, 'Enabled', 'True');
        changed |= config.set(_raSection, 'Username', login.username);
        changed |= config.set(_raSection, 'ApiToken', login.token);
        changed |= config.set(_raSection, 'HardcoreEnabled', (login.hardcore ?? false) ? 'True' : 'False');
        return changed;
      }, create: true, private: true, backup: true, windows: platform.isWindows);
    } catch (e) {
      debugPrint('[Dolphin] Could not apply the RetroAchievements login: $e');
    }
  }

  /// Takes a login for [username] back out (token, username, and achievements
  /// switched off); one for another account stays.
  @override
  Future<void> clearRetroAchievementsLogin(String username) async {
    try {
      final dir = await _configDirectory();
      if (dir == null) return;
      await updateIniFile(io.File(p.join(dir, _raFileName)), (config) {
        final current = config.get(_raSection, 'Username');
        if (current == null || current.toLowerCase() != username.toLowerCase()) return false;
        var changed = false;
        changed |= config.remove(_raSection, 'ApiToken');
        changed |= config.remove(_raSection, 'Username');
        changed |= config.set(_raSection, 'Enabled', 'False');
        return changed;
      });
    } catch (e) {
      debugPrint('[Dolphin] Could not clear the RetroAchievements login: $e');
    }
  }

  @override
  Future<void> postInstall(String installDir) async {
    // Dolphin requires a portable.txt file in the SAME directory as the executable to run in portable mode.
    // This ensures saves and settings are stored in the emulator directory.
    final exePath = await _directoryService.findEmulatorExecutable(emulatorId, windowsExecutable);
    final targetDir = exePath != null ? io.File(exePath).parent.path : installDir;
    
    final portableTxt = io.File(p.join(targetDir, 'portable.txt'));
    if (!await portableTxt.exists()) {
      await portableTxt.create();
      debugPrint('[Dolphin] Created portable.txt at $targetDir to enable portable mode.');
    }
  }
}
