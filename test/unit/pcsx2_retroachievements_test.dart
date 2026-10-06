import 'dart:io' as io;
import 'package:flutter_test/flutter_test.dart';
import 'package:freegosy/core/emulator/strategies/pcsx2_strategy.dart';
import 'package:freegosy/core/platform/platform_info.dart';
import 'package:freegosy/core/retroachievements/retroachievements_emulator_login.dart';
import 'package:freegosy/core/romm/romm_models.dart';
import 'package:freegosy/core/storage/directory_service.dart';
import 'package:freegosy/core/storage/ini_file.dart';
import 'package:freegosy/core/storage/shared_preferences_app_preferences.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import '../helpers/same_path.dart';

/// Answers `findEmulatorExecutable` with a fixed path (or none).
class _FixedExeDirectoryService extends DirectoryService {
  _FixedExeDirectoryService(super.prefs, this.exe);
  final String? exe;

  @override
  Future<String?> findEmulatorExecutable(String emulatorId, String executableName) async => exe;
}

const _iniBefore = '[UI]\nTheme = dark\n\n[Achievements]\nEnabled = false\nChallengeMode = true\nNotifications = true\n\n[Folders]\nBios = bios\n';

void main() {
  late io.Directory home;
  late DirectoryService directoryService;
  final game = Game(id: 'g1', name: 'Ico', platformSlug: 'ps2', fileSize: 0);
  const login = RetroAchievementsEmulatorLogin(username: 'Player', token: 'tok-123');

  Future<Pcsx2Strategy> build({String? exe, PlatformInfo? platform, RetroAchievementsEmulatorLogin? loaded}) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = SharedPreferencesAppPreferences(await SharedPreferences.getInstance());
    directoryService = _FixedExeDirectoryService(prefs, exe);
    return Pcsx2Strategy(directoryService,
        platform: platform ?? PlatformInfo('linux', environment: {'HOME': home.path}),
        raLoginLoader: () async => loaded);
  }

  String inis() => p.join(home.path, '.config', 'PCSX2', 'inis');
  io.File ini() => io.File(p.join(inis(), 'PCSX2.ini'));
  io.File secrets() => io.File(p.join(inis(), 'secrets.ini'));

  Future<void> givenPcsx2Ini([String text = _iniBefore]) async {
    await io.Directory(inis()).create(recursive: true);
    await ini().writeAsString(text);
  }

  setUp(() async {
    home = await io.Directory.systemTemp.createTemp('pcsx2_ra');
  });

  tearDown(() => home.delete(recursive: true));

  test('PCSX2 signs in through its config files', () async {
    expect((await build()).supportsRetroAchievementsLogin, isTrue);
  });

  group('settings folder', () {
    test('Linux default is ~/.config/PCSX2/inis, also for an AppImage next to a portable.ini', () async {
      final appImage = p.join(home.path, 'Emulators', 'pcsx2', 'pcsx2-qt.AppImage');
      await io.File(p.join(p.dirname(appImage), 'portable.ini')).create(recursive: true);
      expect(await (await build(exe: appImage)).settingsDirectory(), inis());
    });

    test('a portable install (portable.ini beside the executable) uses its own inis folder', () async {
      final exe = p.join(home.path, 'pcsx2', 'pcsx2-qt');
      await io.File(p.join(p.dirname(exe), 'portable.ini')).create(recursive: true);
      expect(await (await build(exe: exe)).settingsDirectory(), p.join(home.path, 'pcsx2', 'inis'));
    });

    test('the Flatpak keeps its settings under ~/.var/app', () async {
      expect(await (await build(exe: 'flatpak run net.pcsx2.PCSX2')).settingsDirectory(),
          p.join(home.path, '.var', 'app', 'net.pcsx2.PCSX2', 'config', 'PCSX2', 'inis'));
    });

    test('XDG_CONFIG_HOME is honoured', () async {
      final strategy = await build(
          platform: PlatformInfo('linux', environment: {'HOME': home.path, 'XDG_CONFIG_HOME': '${home.path}/xdg'}));
      expect(await strategy.settingsDirectory(), samePath(p.join(home.path, 'xdg', 'PCSX2', 'inis')));
    });

    test('Windows default is Documents/PCSX2/inis', () async {
      final strategy = await build(platform: PlatformInfo('windows', environment: {'USERPROFILE': home.path}));
      expect(await strategy.settingsDirectory(), p.join(home.path, 'Documents', 'PCSX2', 'inis'));
    });
  });

  group('applyRetroAchievementsLogin', () {
    test('writes the account into PCSX2.ini and the token into secrets.ini, leaving the rest alone', () async {
      await givenPcsx2Ini();
      await (await build()).applyRetroAchievementsLogin(login);

      final config = IniFile(await ini().readAsString());
      expect(config.get('Achievements', 'Enabled'), 'true');
      expect(config.get('Achievements', 'Username'), 'Player');
      expect(int.parse(config.get('Achievements', 'LoginTimestamp')!), greaterThan(1700000000));
      expect(config.get('Achievements', 'ChallengeMode'), 'false', reason: 'hardcore is off unless turned on');
      expect(config.get('Achievements', 'Notifications'), 'true');
      expect(config.get('UI', 'Theme'), 'dark');
      expect(config.get('Folders', 'Bios'), 'bios');
      expect(config.get('Achievements', 'Token'), isNull, reason: 'the token never goes in PCSX2.ini');

      expect(IniFile(await secrets().readAsString()).get('Achievements', 'Token'), 'tok-123');
    });

    test('hardcore on in Settings turns ChallengeMode on', () async {
      await givenPcsx2Ini(_iniBefore.replaceFirst('ChallengeMode = true', 'ChallengeMode = false'));
      await (await build()).applyRetroAchievementsLogin(
          const RetroAchievementsEmulatorLogin(username: 'Player', token: 't', hardcore: true));
      expect(IniFile(await ini().readAsString()).get('Achievements', 'ChallengeMode'), 'true');
    });

    test('PCSX2.ini is backed up once, before the first change', () async {
      await givenPcsx2Ini();
      final strategy = await build();
      await strategy.applyRetroAchievementsLogin(login);
      final backup = io.File('${ini().path}.freegosy.bak');
      expect(await backup.readAsString(), _iniBefore);

      await strategy.applyRetroAchievementsLogin(const RetroAchievementsEmulatorLogin(username: 'Other', token: 'x'));
      expect(await backup.readAsString(), _iniBefore, reason: 'the original stays the backup');
    });

    test('a second launch with the same login rewrites nothing', () async {
      await givenPcsx2Ini();
      final strategy = await build();
      await strategy.applyRetroAchievementsLogin(login);
      final first = await ini().readAsString();
      final firstSecrets = await secrets().readAsString();
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      await strategy.applyRetroAchievementsLogin(login);
      expect(await ini().readAsString(), first, reason: 'LoginTimestamp is kept for the same account');
      expect(await secrets().readAsString(), firstSecrets);
    });

    test('an existing secrets.ini keeps its other entries', () async {
      await givenPcsx2Ini();
      await secrets().writeAsString('[Other]\nKey = value\n');
      await (await build()).applyRetroAchievementsLogin(login);
      final text = IniFile(await secrets().readAsString());
      expect(text.get('Other', 'Key'), 'value');
      expect(text.get('Achievements', 'Token'), 'tok-123');
    });

    test('does nothing before PCSX2 has run (no PCSX2.ini to edit)', () async {
      await (await build()).applyRetroAchievementsLogin(login);
      expect(await io.Directory(inis()).exists(), isFalse);
    });

    test('secrets.ini is readable by its owner only (not on Windows)', () async {
      await givenPcsx2Ini();
      await (await build()).applyRetroAchievementsLogin(login);
      if (!io.Platform.isWindows) {
        final mode = (await secrets().stat()).mode & 0x1FF;
        expect(mode, 384, reason: '0600'); // 0o600
      }
    });
  });

  group('preLaunch', () {
    test('signs in with the saved login before launch', () async {
      await givenPcsx2Ini();
      await (await build(loaded: login)).preLaunch(game, '/roms/Ico.iso');
      expect(IniFile(await ini().readAsString()).get('Achievements', 'Username'), 'Player');
    });

    test('leaves PCSX2 alone when no account is connected', () async {
      await givenPcsx2Ini();
      await (await build(loaded: null)).preLaunch(game, '/roms/Ico.iso');
      expect(await ini().readAsString(), _iniBefore);
      expect(await secrets().exists(), isFalse);
    });
  });

  group('clearRetroAchievementsLogin', () {
    test('takes Freegosy\'s login out: token, username, timestamp, and Enabled off', () async {
      await givenPcsx2Ini();
      final strategy = await build();
      await strategy.applyRetroAchievementsLogin(login);
      await strategy.clearRetroAchievementsLogin('player'); // case-insensitive

      final config = IniFile(await ini().readAsString());
      expect(config.get('Achievements', 'Username'), isNull);
      expect(config.get('Achievements', 'LoginTimestamp'), isNull);
      expect(config.get('Achievements', 'Enabled'), 'false');
      expect(config.get('Achievements', 'Notifications'), 'true');
      expect(IniFile(await secrets().readAsString()).get('Achievements', 'Token'), isNull);
    });

    test('a login the user set up themselves for another account stays', () async {
      await givenPcsx2Ini('[Achievements]\nEnabled = true\nUsername = Someone\n');
      await secrets().writeAsString('[Achievements]\nToken = theirs\n');
      await (await build()).clearRetroAchievementsLogin('Player');

      expect(IniFile(await ini().readAsString()).get('Achievements', 'Username'), 'Someone');
      expect(IniFile(await secrets().readAsString()).get('Achievements', 'Token'), 'theirs');
    });

    test('is harmless when PCSX2 has no config', () async {
      await (await build()).clearRetroAchievementsLogin('Player');
      expect(await io.Directory(inis()).exists(), isFalse);
    });
  });
}
