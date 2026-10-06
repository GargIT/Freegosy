import 'dart:io' as io;
import 'package:flutter_test/flutter_test.dart';
import 'package:freegosy/core/emulator/strategies/dolphin_strategy.dart';
import 'package:freegosy/core/platform/platform_info.dart';
import 'package:freegosy/core/retroachievements/retroachievements_emulator_login.dart';
import 'package:freegosy/core/romm/romm_models.dart';
import 'package:freegosy/core/storage/directory_service.dart';
import 'package:freegosy/core/storage/ini_file.dart';
import 'package:freegosy/core/storage/shared_preferences_app_preferences.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import '../helpers/same_path.dart';

class _FixedExeDirectoryService extends DirectoryService {
  _FixedExeDirectoryService(super.prefs, this.exe);
  final String? exe;

  @override
  Future<String?> findEmulatorExecutable(String emulatorId, String executableName) async => exe;
}

void main() {
  late io.Directory home;
  final game = Game(id: 'g1', name: 'Metroid Prime', platformSlug: 'gc', fileSize: 0);
  const login = RetroAchievementsEmulatorLogin(username: 'Player', token: 'tok-123');

  Future<DolphinStrategy> build({String? exe, PlatformInfo? platform, RetroAchievementsEmulatorLogin? loaded}) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = SharedPreferencesAppPreferences(await SharedPreferences.getInstance());
    return DolphinStrategy(_FixedExeDirectoryService(prefs, exe),
        platform: platform ?? PlatformInfo('linux', environment: {'HOME': home.path}),
        raLoginLoader: () async => loaded);
  }

  String config() => p.join(home.path, '.config', 'dolphin-emu');
  io.File raIni() => io.File(p.join(config(), 'RetroAchievements.ini'));

  Future<void> givenDolphinRan([String? dir]) async {
    final d = dir ?? config();
    await io.Directory(d).create(recursive: true);
    await io.File(p.join(d, 'Dolphin.ini')).writeAsString('[General]\nUSBDeviceHotplug = True\n');
  }

  setUp(() async {
    home = await io.Directory.systemTemp.createTemp('dolphin_ra');
  });

  tearDown(() => home.delete(recursive: true));

  test('Dolphin signs in through its config files', () async {
    expect((await build()).supportsRetroAchievementsLogin, isTrue);
  });

  group('config folder candidates', () {
    test('Linux: Flatpak, legacy ~/.dolphin-emu, then XDG', () async {
      expect(await (await build()).candidateConfigDirectories(), [
        p.join(home.path, '.var', 'app', 'org.DolphinEmu.dolphin-emu', 'config', 'dolphin-emu'),
        p.join(home.path, '.dolphin-emu', 'Config'),
        config(),
      ]);
    });

    test('a portable install (executable with a User folder) is tried first', () async {
      final exe = p.join(home.path, 'Dolphin', 'Dolphin.exe');
      final dirs = await (await build(exe: exe, platform: PlatformInfo('windows', environment: {'USERPROFILE': home.path, 'APPDATA': '${home.path}/AppData'})))
          .candidateConfigDirectories();
      expect(dirs.first, p.join(home.path, 'Dolphin', 'User', 'Config'));
      expect(dirs, contains(p.join(home.path, 'Documents', 'Dolphin Emulator', 'Config')));
      expect(dirs, anyElement(samePath(p.join(home.path, 'AppData', 'Dolphin Emulator', 'Config'))));
    });

    test('an AppImage is not treated as portable', () async {
      final dirs = await (await build(exe: p.join(home.path, 'Emulators', 'dolphin', 'Dolphin.AppImage'))).candidateConfigDirectories();
      expect(dirs.any((d) => d.endsWith(p.join('User', 'Config'))), isFalse);
    });

    test('macOS: Application Support', () async {
      final dirs = await (await build(platform: PlatformInfo('macos', environment: {'HOME': home.path}))).candidateConfigDirectories();
      expect(dirs, [p.join(home.path, 'Library', 'Application Support', 'Dolphin', 'Config')]);
    });
  });

  group('applyRetroAchievementsLogin', () {
    test('writes the account and token into RetroAchievements.ini, owner-readable', () async {
      await givenDolphinRan();
      await (await build()).applyRetroAchievementsLogin(login);

      final text = IniFile(await raIni().readAsString());
      expect(text.get('Achievements', 'Enabled'), 'True');
      expect(text.get('Achievements', 'Username'), 'Player');
      expect(text.get('Achievements', 'ApiToken'), 'tok-123');
      expect(text.get('Achievements', 'HardcoreEnabled'), 'False', reason: 'hardcore is off unless turned on');
      if (!io.Platform.isWindows) expect((await raIni().stat()).mode & 0x1FF, 384, reason: '0600');
    });

    test('keeps other settings in an existing RetroAchievements.ini and backs it up once', () async {
      await givenDolphinRan();
      const before = '[Achievements]\nDiscordPresenceEnabled = True\nHardcoreEnabled = True\n';
      await raIni().writeAsString(before);
      final strategy = await build();
      await strategy.applyRetroAchievementsLogin(login);
      await strategy.applyRetroAchievementsLogin(const RetroAchievementsEmulatorLogin(username: 'Other', token: 'x'));

      final text = IniFile(await raIni().readAsString());
      expect(text.get('Achievements', 'DiscordPresenceEnabled'), 'True');
      expect(text.get('Achievements', 'HardcoreEnabled'), 'False', reason: 'Freegosy owns hardcore, default off');
      expect(await io.File('${raIni().path}.freegosy.bak').readAsString(), before);
    });

    test('hardcore on in Settings turns HardcoreEnabled on', () async {
      await givenDolphinRan();
      await (await build()).applyRetroAchievementsLogin(
          const RetroAchievementsEmulatorLogin(username: 'Player', token: 't', hardcore: true));
      expect(IniFile(await raIni().readAsString()).get('Achievements', 'HardcoreEnabled'), 'True');
    });

    test('works from a legacy or Flatpak config folder too', () async {
      final flatpak = p.join(home.path, '.var', 'app', 'org.DolphinEmu.dolphin-emu', 'config', 'dolphin-emu');
      await givenDolphinRan(flatpak);
      await (await build()).applyRetroAchievementsLogin(login);
      expect(await io.File(p.join(flatpak, 'RetroAchievements.ini')).exists(), isTrue);
      expect(await raIni().exists(), isFalse);
    });

    test('signs in on the very first launch: with no Dolphin.ini yet it writes to the default folder', () async {
      await (await build()).applyRetroAchievementsLogin(login);
      expect(IniFile(await raIni().readAsString()).get('Achievements', 'Username'), 'Player');
    });

    test('before its first run the Flatpak gets the login in its own config folder', () async {
      await (await build(exe: 'flatpak run org.DolphinEmu.dolphin-emu')).applyRetroAchievementsLogin(login);
      final flatpak = p.join(home.path, '.var', 'app', 'org.DolphinEmu.dolphin-emu', 'config', 'dolphin-emu');
      expect(await io.File(p.join(flatpak, 'RetroAchievements.ini')).exists(), isTrue);
      expect(await raIni().exists(), isFalse);
    });

    test('before its first run, a portable Windows install (portable.txt) gets User/Config', () async {
      final exe = p.join(home.path, 'Dolphin', 'Dolphin.exe');
      await io.File(p.join(p.dirname(exe), 'portable.txt')).create(recursive: true);
      final strategy = await build(exe: exe, platform: PlatformInfo('windows', environment: {'USERPROFILE': home.path, 'APPDATA': '${home.path}/AppData'}));
      expect(await strategy.preferredConfigDirectory(), p.join(home.path, 'Dolphin', 'User', 'Config'));
    });

    test('before its first run, Windows falls back to Documents (if Dolphin\'s folder is there) or APPDATA', () async {
      final env = {'USERPROFILE': home.path, 'APPDATA': '${home.path}/AppData'};
      final noDocs = await build(platform: PlatformInfo('windows', environment: env));
      expect(await noDocs.preferredConfigDirectory(), samePath(p.join(home.path, 'AppData', 'Dolphin Emulator', 'Config')));
      await io.Directory(p.join(home.path, 'Documents', 'Dolphin Emulator')).create(recursive: true);
      expect(await noDocs.preferredConfigDirectory(), p.join(home.path, 'Documents', 'Dolphin Emulator', 'Config'));
    });
  });

  group('preLaunch', () {
    test('signs in with the saved login', () async {
      await givenDolphinRan();
      await (await build(loaded: login)).preLaunch(game, '/roms/mp.rvz');
      expect(IniFile(await raIni().readAsString()).get('Achievements', 'Username'), 'Player');
    });

    test('leaves Dolphin alone when no account is connected', () async {
      await givenDolphinRan();
      await (await build(loaded: null)).preLaunch(game, '/roms/mp.rvz');
      expect(await raIni().exists(), isFalse);
    });
  });

  group('clearRetroAchievementsLogin', () {
    test('takes Freegosy\'s login out: token, username, and achievements off', () async {
      await givenDolphinRan();
      final strategy = await build();
      await strategy.applyRetroAchievementsLogin(login);
      await strategy.clearRetroAchievementsLogin('player');

      final text = IniFile(await raIni().readAsString());
      expect(text.get('Achievements', 'ApiToken'), isNull);
      expect(text.get('Achievements', 'Username'), isNull);
      expect(text.get('Achievements', 'Enabled'), 'False');
    });

    test('a login the user set up for another account stays', () async {
      await givenDolphinRan();
      await raIni().writeAsString('[Achievements]\nEnabled = True\nUsername = Someone\nApiToken = theirs\n');
      await (await build()).clearRetroAchievementsLogin('Player');
      final text = IniFile(await raIni().readAsString());
      expect(text.get('Achievements', 'Username'), 'Someone');
      expect(text.get('Achievements', 'ApiToken'), 'theirs');
    });
  });
}
