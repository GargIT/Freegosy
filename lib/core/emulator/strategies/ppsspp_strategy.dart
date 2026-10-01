import 'dart:io' as io;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:freegosy/core/emulator/emulator_strategy.dart';
import 'package:freegosy/core/retroachievements/retroachievements_emulator_login.dart';
import 'package:freegosy/core/romm/romm_models.dart';
import 'package:freegosy/core/storage/directory_service.dart';
import 'package:freegosy/core/storage/ini_file.dart';

class PPSSPPStrategy extends EmulatorStrategy {
  final DirectoryService _directoryService;
  final Future<RetroAchievementsEmulatorLogin?> Function()? _raLoginLoader;

  PPSSPPStrategy(
    this._directoryService, {
    super.platform,
    Future<RetroAchievementsEmulatorLogin?> Function()? raLoginLoader,
  }) : _raLoginLoader = raLoginLoader;

  @override
  DirectoryService get directoryService => _directoryService;

  @override
  String get name => 'PPSSPP';

  @override
  String get emulatorId => 'ppsspp';

  @override
  List<String> get supportedSlugs => ['psp', 'playstation-portable'];

  @override
  String get windowsExecutable => 'PPSSPPWindows64.exe';

  @override
  String get linuxExecutable => 'PPSSPP';

  @override
  String get macosExecutable => 'PPSSPPSDL.app/Contents/MacOS/PPSSPPSDL';

  @override
  bool get supportsSaveSync => true;

  @override
  bool get supportsRetroAchievementsLogin => true;

  @override
  String resolveSavePath(Game game) => '';

  // ── RetroAchievements ────────────────────────────────────────

  static const _raSection = 'Achievements';

  /// PPSSPP keeps the RetroAchievements token in a file of its own, not in
  /// ppsspp.ini ("so the ini can be posted for debugging"): the secret named
  /// `retroachievements`, stored as the bare token.
  static const _tokenFileName = 'ppsspp_retroachievements.dat';

  /// The folders that may hold PPSSPP's `ppsspp.ini` and token file
  /// (`<memstick>/PSP/SYSTEM`), most likely first: the Flatpak's, a portable
  /// install's `memstick` beside the executable, and the platform default.
  /// macOS is left out: where PPSSPP keeps its memstick there isn't settled.
  @visibleForTesting
  Future<List<String>> candidateSystemDirectories() async {
    final home = platform.environment['HOME'] ?? '';
    final exe = await findExecutable();
    final result = <String>[];
    if (exe != null && exe.startsWith('flatpak ')) {
      final package = exe.split(' ').last;
      result.add(p.join(home, '.var', 'app', package, 'config', 'ppsspp', 'PSP', 'SYSTEM'));
    } else if (exe != null && !exe.toLowerCase().endsWith('.appimage')) {
      result.add(p.join(io.File(exe).parent.path, 'memstick', 'PSP', 'SYSTEM'));
    }
    if (platform.isWindows) {
      final profile = platform.environment['USERPROFILE'];
      if (profile != null && profile.isNotEmpty) result.add(p.join(profile, 'Documents', 'PPSSPP', 'PSP', 'SYSTEM'));
    } else if (platform.isLinux) {
      final xdg = platform.environment['XDG_CONFIG_HOME'];
      final config = xdg != null && xdg.isNotEmpty ? xdg : (home.isEmpty ? null : p.join(home, '.config'));
      if (config != null) result.add(p.join(config, 'ppsspp', 'PSP', 'SYSTEM'));
    }
    return result;
  }

  /// The first candidate folder where PPSSPP has already made its ppsspp.ini,
  /// or null (PPSSPP has not run yet, or its folder isn't one we know).
  Future<String?> _systemDirectory() async {
    for (final dir in await candidateSystemDirectories()) {
      if (await io.File(p.join(dir, 'ppsspp.ini')).exists()) return dir;
    }
    return null;
  }

  /// Signs PPSSPP in before it starts. Never fails a launch.
  @override
  Future<void> preLaunch(Game game, String romPath) async {
    try {
      final login = await (_raLoginLoader ?? () => RetroAchievementsEmulatorLogin.load(_directoryService.prefs))();
      if (login != null) await applyRetroAchievementsLogin(login);
    } catch (e) {
      debugPrint('[PPSSPP] Skipping RetroAchievements login: $e');
    }
  }

  /// PPSSPP has no command-line option for this, so the login goes into its
  /// files: `AchievementsEnable`, `AchievementsUserName` and
  /// `AchievementsChallengeMode` (hardcore, off unless turned on in Settings)
  /// in ppsspp.ini's `[Achievements]`, and the token in its own file beside
  /// it. Only differing lines change, ppsspp.ini is copied to
  /// `ppsspp.ini.freegosy.bak` first (once), and nothing is written before
  /// PPSSPP has run once.
  @override
  Future<void> applyRetroAchievementsLogin(RetroAchievementsEmulatorLogin login) async {
    try {
      final dir = await _systemDirectory();
      if (dir == null) {
        debugPrint('[PPSSPP] RetroAchievements login not applied: no ppsspp.ini found (has PPSSPP been run?)');
        return;
      }
      await _writeToken(io.File(p.join(dir, _tokenFileName)), login.token);
      await updateIniFile(io.File(p.join(dir, 'ppsspp.ini')), (config) {
        var changed = false;
        changed |= config.set(_raSection, 'AchievementsEnable', 'True');
        changed |= config.set(_raSection, 'AchievementsUserName', login.username);
        changed |= config.set(_raSection, 'AchievementsChallengeMode', (login.hardcore ?? false) ? 'True' : 'False');
        return changed;
      }, backup: true);
    } catch (e) {
      debugPrint('[PPSSPP] Could not apply the RetroAchievements login: $e');
    }
  }

  /// Takes a login for [username] back out (token file, username, and
  /// achievements switched off); one for another account stays.
  @override
  Future<void> clearRetroAchievementsLogin(String username) async {
    try {
      final dir = await _systemDirectory();
      if (dir == null) return;
      final iniFile = io.File(p.join(dir, 'ppsspp.ini'));
      final current = IniFile(await iniFile.readAsString()).get(_raSection, 'AchievementsUserName');
      if (current == null || current.toLowerCase() != username.toLowerCase()) return;

      final token = io.File(p.join(dir, _tokenFileName));
      if (await token.exists()) await token.delete();
      await updateIniFile(iniFile, (config) {
        var changed = false;
        changed |= config.remove(_raSection, 'AchievementsUserName');
        changed |= config.set(_raSection, 'AchievementsEnable', 'False');
        return changed;
      });
    } catch (e) {
      debugPrint('[PPSSPP] Could not clear the RetroAchievements login: $e');
    }
  }

  /// Writes the bare token, owner-readable only, unless the file already
  /// holds it.
  Future<void> _writeToken(io.File file, String token) async {
    if (await file.exists() && await file.readAsString() == token) return;
    if (!await file.exists()) {
      await file.writeAsString('', flush: true);
    }
    if (!platform.isWindows) await io.Process.run('chmod', ['600', file.path]);
    await file.writeAsString(token, flush: true);
  }
}
