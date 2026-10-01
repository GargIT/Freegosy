import 'dart:io' as io;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:freegosy/core/emulator/emulator_strategy.dart';
import 'package:freegosy/core/emulator/pe_version_reader.dart';
import 'package:freegosy/core/platform/platform_info.dart';
import 'package:freegosy/core/retroachievements/retroachievements_emulator_login.dart';
import 'package:freegosy/core/romm/romm_models.dart';
import 'package:freegosy/core/storage/directory_service.dart';
import 'package:freegosy/core/storage/ini_file.dart';

class Pcsx2Strategy extends EmulatorStrategy {
  final DirectoryService _directoryService;
  final Future<RetroAchievementsEmulatorLogin?> Function()? _raLoginLoader;

  Pcsx2Strategy(
    this._directoryService, {
    super.platform,
    Future<RetroAchievementsEmulatorLogin?> Function()? raLoginLoader,
  }) : _raLoginLoader = raLoginLoader;

  @override
  DirectoryService get directoryService => _directoryService;

  @override
  List<String> get launchArgs => ['-batch', '-fullscreen'];

  @override
  String get name => 'PCSX2';

  @override
  String get emulatorId => 'pcsx2';

  @override
  List<String> get supportedSlugs => ['ps2', 'playstation-2', 'playstation2'];

  @override
  String get windowsExecutable => 'pcsx2-qt.exe';

  @override
  String get linuxExecutable => 'pcsx2-qt.AppImage';

  @override
  String get macosExecutable => 'PCSX2.app/Contents/MacOS/PCSX2';

  @override
  bool get supportsSaveSync => true;

  @override
  bool get supportsStateSync => true;

  @override
  bool get supportsStateLoadOnLaunch => true;

  @override
  bool get supportsRetroAchievementsLogin => true;

  /// PCSX2: `-statefile <filename>` loads the given state at boot.
  @override
  List<String> stateLoadArgs(String statePath) => ['-statefile', statePath];

  /// Windows: the file version of `pcsx2-qt.exe` (e.g. `2.8.2.0`). Linux
  /// AppImage/Flatpak and macOS builds carry no such resource: null.
  @override
  Future<String?> installedVersion() async {
    if (!platform.isWindows) return null;
    try {
      final exe = await findExecutable();
      return exe == null ? null : await PeVersionReader.fileVersion(exe);
    } catch (_) {
      return null;
    }
  }

  @override
  String resolveSavePath(Game game) {
    if (platform.isMacOS) {
      final home = platform.environment['HOME'];
      if (home != null) {
        return '$home/Library/Application Support/PCSX2/';
      }
    }
    return '';
  }

  // ── RetroAchievements ────────────────────────────────────────

  static const _raSection = 'Achievements';

  /// PCSX2's settings folder (`inis`, holding PCSX2.ini and secrets.ini):
  /// the Flatpak's, the portable install's (portable.ini beside a real
  /// executable; an AppImage doesn't count, PCSX2 looks for it inside the
  /// mounted image), else the platform's default. Null when it can't be told.
  @visibleForTesting
  Future<String?> settingsDirectory() async {
    final home = platform.environment['HOME'] ?? '';
    final exe = await findExecutable();
    if (exe != null && exe.startsWith('flatpak ')) {
      final package = exe.split(' ').last;
      return p.join(home, '.var', 'app', package, 'config', 'PCSX2', 'inis');
    }
    if (exe != null && !exe.toLowerCase().endsWith('.appimage')) {
      var exeDir = io.File(exe).parent.path;
      if (platform.isMacOS && exe.contains('.app/Contents/MacOS/')) {
        exeDir = io.File(exe).parent.parent.parent.parent.path;
      }
      if (await io.File(p.join(exeDir, 'portable.ini')).exists()) return p.join(exeDir, 'inis');
    }
    if (platform.isWindows) {
      final profile = platform.environment['USERPROFILE'];
      return profile == null || profile.isEmpty ? null : p.join(profile, 'Documents', 'PCSX2', 'inis');
    }
    if (platform.isMacOS) {
      return home.isEmpty ? null : p.join(home, 'Library', 'Application Support', 'PCSX2', 'inis');
    }
    final xdg = platform.environment['XDG_CONFIG_HOME'];
    final config = xdg != null && xdg.isNotEmpty ? xdg : p.join(home, '.config');
    return home.isEmpty && (xdg == null || xdg.isEmpty) ? null : p.join(config, 'PCSX2', 'inis');
  }

  /// Signs PCSX2 in before it starts. Never fails a launch.
  @override
  Future<void> preLaunch(Game game, String romPath) async {
    try {
      final login = await (_raLoginLoader ?? () => RetroAchievementsEmulatorLogin.load(_directoryService.prefs))();
      if (login != null) await applyRetroAchievementsLogin(login);
    } catch (e) {
      debugPrint('[PCSX2] Skipping RetroAchievements login: $e');
    }
  }

  /// PCSX2 has no command-line option for settings, so the login goes into
  /// its files: `Enabled`, `Username`, `LoginTimestamp` and `ChallengeMode`
  /// (hardcore, off unless turned on in Settings) in PCSX2.ini's
  /// `[Achievements]`, and the token in secrets.ini beside it. Only the lines
  /// that differ are changed, PCSX2.ini is copied to `PCSX2.ini.freegosy.bak`
  /// first (once), and nothing is written before PCSX2 has run once (its
  /// first-run setup would otherwise find a half-made config).
  @override
  Future<void> applyRetroAchievementsLogin(RetroAchievementsEmulatorLogin login) async {
    try {
      final dir = await settingsDirectory();
      if (dir == null) return;
      final iniFile = io.File(p.join(dir, 'PCSX2.ini'));
      if (!await iniFile.exists()) {
        debugPrint('[PCSX2] RetroAchievements login not applied: PCSX2 has not been run yet (no PCSX2.ini)');
        return;
      }

      await updateIniFile(io.File(p.join(dir, 'secrets.ini')), (secrets) => secrets.set(_raSection, 'Token', login.token),
          private: true, create: true, windows: platform.isWindows);

      await updateIniFile(iniFile, (config) {
        var changed = false;
        final newUser = config.get(_raSection, 'Username') != login.username;
        changed |= config.set(_raSection, 'Enabled', 'true');
        changed |= config.set(_raSection, 'Username', login.username);
        if (newUser || config.get(_raSection, 'LoginTimestamp') == null) {
          changed |= config.set(_raSection, 'LoginTimestamp', '${DateTime.now().millisecondsSinceEpoch ~/ 1000}');
        }
        changed |= config.set(_raSection, 'ChallengeMode', '${login.hardcore ?? false}');
        return changed;
      }, backup: true);
    } catch (e) {
      debugPrint('[PCSX2] Could not apply the RetroAchievements login: $e');
    }
  }

  /// Takes a login for [username] back out: the token, the username and the
  /// timestamp, and switches achievements off. A login for another account
  /// (set up in PCSX2 itself) is left alone.
  @override
  Future<void> clearRetroAchievementsLogin(String username) async {
    try {
      final dir = await settingsDirectory();
      if (dir == null) return;
      final iniFile = io.File(p.join(dir, 'PCSX2.ini'));
      if (!await iniFile.exists()) return;
      final current = IniFile(await iniFile.readAsString()).get(_raSection, 'Username');
      if (current == null || current.toLowerCase() != username.toLowerCase()) return;

      await updateIniFile(io.File(p.join(dir, 'secrets.ini')), (secrets) => secrets.remove(_raSection, 'Token'));
      await updateIniFile(iniFile, (config) {
        var changed = false;
        changed |= config.remove(_raSection, 'Username');
        changed |= config.remove(_raSection, 'LoginTimestamp');
        changed |= config.set(_raSection, 'Enabled', 'false');
        return changed;
      });
    } catch (e) {
      debugPrint('[PCSX2] Could not clear the RetroAchievements login: $e');
    }
  }

  @override
  Future<void> postInstall(String installDir) async {
    // PCSX2 requires a portable.ini file in the SAME directory as the executable to run in portable mode.
    // This ensures saves and settings are stored in the emulator directory.
    final exePath = await _directoryService.findEmulatorExecutable(emulatorId, windowsExecutable);
    final targetDir = exePath != null ? io.File(exePath).parent.path : installDir;
    
    final portableIni = io.File(p.join(targetDir, 'portable.ini'));
    if (!await portableIni.exists()) {
      await portableIni.create();
      debugPrint('[PCSX2] Created portable.ini at $targetDir to enable portable mode.');
    }
  }
}
