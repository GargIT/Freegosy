import 'dart:io' as io;
import 'package:flutter_test/flutter_test.dart';
import 'package:freegosy/core/emulator/strategies/ppsspp_strategy.dart';
import 'package:freegosy/core/platform/platform_info.dart';
import 'package:freegosy/core/retroachievements/retroachievements_emulator_login.dart';
import 'package:freegosy/core/romm/romm_models.dart';
import 'package:freegosy/core/storage/directory_service.dart';
import 'package:freegosy/core/storage/ini_file.dart';
import 'package:freegosy/core/storage/shared_preferences_app_preferences.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

class _FixedExeDirectoryService extends DirectoryService {
  _FixedExeDirectoryService(super.prefs, this.exe);
  final String? exe;

  @override
  Future<String?> findEmulatorExecutable(String emulatorId, String executableName) async => exe;
}

const _iniBefore = '[General]\nCurrentDirectory = /roms\n\n[Achievements]\nAchievementsEnable = False\nAchievementsChallengeMode = True\nAchievementsSoundEffects = True\n';

void main() {
  late io.Directory home;
  final game = Game(id: 'g1', name: 'Tekken 6', platformSlug: 'psp', fileSize: 0);
  const login = RetroAchievementsEmulatorLogin(username: 'Player', token: 'tok-123');

  Future<PPSSPPStrategy> build({String? exe, PlatformInfo? platform, RetroAchievementsEmulatorLogin? loaded}) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = SharedPreferencesAppPreferences(await SharedPreferences.getInstance());
    return PPSSPPStrategy(_FixedExeDirectoryService(prefs, exe),
        platform: platform ?? PlatformInfo('linux', environment: {'HOME': home.path}),
        raLoginLoader: () async => loaded);
  }

  String system() => p.join(home.path, '.config', 'ppsspp', 'PSP', 'SYSTEM');
  io.File ini() => io.File(p.join(system(), 'ppsspp.ini'));
  io.File token() => io.File(p.join(system(), 'ppsspp_retroachievements.dat'));

  Future<void> givenPpssppIni([String text = _iniBefore]) async {
    await io.Directory(system()).create(recursive: true);
    await ini().writeAsString(text);
  }

  setUp(() async {
    home = await io.Directory.systemTemp.createTemp('ppsspp_ra');
  });

  tearDown(() => home.delete(recursive: true));

  test('PPSSPP signs in through its config files', () async {
    expect((await build()).supportsRetroAchievementsLogin, isTrue);
  });

  group('settings folder candidates', () {
    test('Linux: ~/.config/ppsspp/PSP/SYSTEM, honouring XDG_CONFIG_HOME', () async {
      expect(await (await build()).candidateSystemDirectories(), [system()]);
      final xdg = await build(platform: PlatformInfo('linux', environment: {'HOME': home.path, 'XDG_CONFIG_HOME': '${home.path}/xdg'}));
      expect(await xdg.candidateSystemDirectories(), [p.join(home.path, 'xdg', 'ppsspp', 'PSP', 'SYSTEM')]);
    });

    test('the Flatpak comes first', () async {
      final dirs = await (await build(exe: 'flatpak run org.ppsspp.PPSSPP')).candidateSystemDirectories();
      expect(dirs.first, p.join(home.path, '.var', 'app', 'org.ppsspp.PPSSPP', 'config', 'ppsspp', 'PSP', 'SYSTEM'));
    });

    test('Windows: the portable memstick beside the executable, then Documents', () async {
      final exe = p.join(home.path, 'PPSSPP', 'PPSSPPWindows64.exe');
      final strategy = await build(exe: exe, platform: PlatformInfo('windows', environment: {'USERPROFILE': home.path}));
      expect(await strategy.candidateSystemDirectories(), [
        p.join(home.path, 'PPSSPP', 'memstick', 'PSP', 'SYSTEM'),
        p.join(home.path, 'Documents', 'PPSSPP', 'PSP', 'SYSTEM'),
      ]);
    });
  });

  group('applyRetroAchievementsLogin', () {
    test('writes the account into ppsspp.ini and the bare token into its own file', () async {
      await givenPpssppIni();
      await (await build()).applyRetroAchievementsLogin(login);

      final config = IniFile(await ini().readAsString());
      expect(config.get('Achievements', 'AchievementsEnable'), 'True');
      expect(config.get('Achievements', 'AchievementsUserName'), 'Player');
      expect(config.get('Achievements', 'AchievementsChallengeMode'), 'False', reason: 'hardcore is off unless turned on');
      expect(config.get('Achievements', 'AchievementsSoundEffects'), 'True');
      expect(config.get('General', 'CurrentDirectory'), '/roms');
      expect(await ini().readAsString(), isNot(contains('tok-123')), reason: 'the token never goes in ppsspp.ini');

      expect(await token().readAsString(), 'tok-123', reason: 'bare token, no newline');
      if (!io.Platform.isWindows) expect((await token().stat()).mode & 0x1FF, 384, reason: '0600');
    });

    test('hardcore on in Settings turns AchievementsChallengeMode on', () async {
      await givenPpssppIni(_iniBefore.replaceFirst('ChallengeMode = True', 'ChallengeMode = False'));
      await (await build()).applyRetroAchievementsLogin(
          const RetroAchievementsEmulatorLogin(username: 'Player', token: 't', hardcore: true));
      expect(IniFile(await ini().readAsString()).get('Achievements', 'AchievementsChallengeMode'), 'True');
    });

    test('ppsspp.ini is backed up once', () async {
      await givenPpssppIni();
      final strategy = await build();
      await strategy.applyRetroAchievementsLogin(login);
      await strategy.applyRetroAchievementsLogin(const RetroAchievementsEmulatorLogin(username: 'Other', token: 'x'));
      expect(await io.File('${ini().path}.freegosy.bak').readAsString(), _iniBefore);
    });

    test('a changed token is rewritten', () async {
      await givenPpssppIni();
      final strategy = await build();
      await strategy.applyRetroAchievementsLogin(login);
      await strategy.applyRetroAchievementsLogin(const RetroAchievementsEmulatorLogin(username: 'Player', token: 'new-token'));
      expect(await token().readAsString(), 'new-token');
    });

    test('does nothing before PPSSPP has run (no ppsspp.ini)', () async {
      await (await build()).applyRetroAchievementsLogin(login);
      expect(await io.Directory(system()).exists(), isFalse);
    });
  });

  group('preLaunch', () {
    test('signs in with the saved login', () async {
      await givenPpssppIni();
      await (await build(loaded: login)).preLaunch(game, '/roms/Tekken6.iso');
      expect(IniFile(await ini().readAsString()).get('Achievements', 'AchievementsUserName'), 'Player');
    });

    test('leaves PPSSPP alone when no account is connected', () async {
      await givenPpssppIni();
      await (await build(loaded: null)).preLaunch(game, '/roms/Tekken6.iso');
      expect(await ini().readAsString(), _iniBefore);
      expect(await token().exists(), isFalse);
    });
  });

  group('clearRetroAchievementsLogin', () {
    test('takes Freegosy\'s login out: token file, username, and achievements off', () async {
      await givenPpssppIni();
      final strategy = await build();
      await strategy.applyRetroAchievementsLogin(login);
      await strategy.clearRetroAchievementsLogin('player');

      final config = IniFile(await ini().readAsString());
      expect(config.get('Achievements', 'AchievementsUserName'), isNull);
      expect(config.get('Achievements', 'AchievementsEnable'), 'False');
      expect(config.get('Achievements', 'AchievementsSoundEffects'), 'True');
      expect(await token().exists(), isFalse);
    });

    test('a login the user set up for another account stays', () async {
      await givenPpssppIni('[Achievements]\nAchievementsEnable = True\nAchievementsUserName = Someone\n');
      await token().writeAsString('theirs');
      await (await build()).clearRetroAchievementsLogin('Player');
      expect(IniFile(await ini().readAsString()).get('Achievements', 'AchievementsUserName'), 'Someone');
      expect(await token().readAsString(), 'theirs');
    });
  });
}
