import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:freegosy/core/storage/app_preferences.dart';
import 'package:freegosy/core/storage/secure_storage_service.dart';

/// Storage keys shared by the Settings flow (which writes them) and the
/// emulator strategies (which read them at launch).
const kRaUsernameKey = 'retroAchievementsUsername';
const kRaWebApiKeySecureKey = 'retroAchievementsWebApiKey';
const kRaConnectTokenSecureKey = 'retroAchievementsConnectToken';
const kRaHardcoreKey = 'retroAchievementsHardcore';

/// Filename of the `--appendconfig` file [RetroArchStrategy] writes the RA
/// token to. Shared with [RetroAchievementsEmulatorLogin.deleteEmulatorFiles]
/// so disconnecting doesn't leave it behind.
const kRetroArchAchievementsConfigFileName = 'retroarch_achievements.cfg';

/// What an emulator needs to sign in to RetroAchievements: the username and
/// the Connect API token RA issued when the user gave Freegosy their password
/// once. The password itself is never stored.
class RetroAchievementsEmulatorLogin {
  final String username;
  final String token;
  final bool hardcore;

  const RetroAchievementsEmulatorLogin({required this.username, required this.token, this.hardcore = false});

  /// Null when no account is connected or it was connected without a
  /// password (Web-API-only), in which case emulators are left untouched.
  static Future<RetroAchievementsEmulatorLogin?> load(AppPreferences prefs) async {
    final username = prefs.getString(kRaUsernameKey) ?? '';
    // Checked first so launches without an RA account never touch the keychain.
    if (username.isEmpty) return null;
    final token = await SecureStorageService.read(kRaConnectTokenSecureKey, prefs) ?? '';
    if (token.isEmpty) return null;
    return RetroAchievementsEmulatorLogin(
      username: username,
      token: token,
      hardcore: prefs.getBool(kRaHardcoreKey) ?? false,
    );
  }

  /// Deletes the on-disk `--appendconfig` files emulator strategies wrote
  /// the RA token into (currently just RetroArch's), so disconnecting in
  /// Settings doesn't leave the token behind on disk. Never throws — a
  /// missing or unwritable file isn't a reason to fail disconnect.
  static Future<void> deleteEmulatorFiles() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File(p.join(dir.path, kRetroArchAchievementsConfigFileName));
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Best-effort: disconnect still clears the credentials that matter.
    }
  }

  /// RetroArch config overrides, passed via `--appendconfig` so the user's
  /// own retroarch.cfg is never edited by Freegosy.
  String toRetroArchConfig() {
    // Drop quotes and line breaks so a value can't end its string or add cfg lines.
    String quote(String v) => '"${v.replaceAll(RegExp(r'["\r\n]'), '')}"';
    return [
      'cheevos_enable = "true"',
      'cheevos_username = ${quote(username)}',
      // Empty so RetroArch signs in with the token rather than a stale password.
      'cheevos_password = ""',
      'cheevos_token = ${quote(token)}',
      'cheevos_hardcore_mode_enable = "$hardcore"',
      '',
    ].join('\n');
  }
}
