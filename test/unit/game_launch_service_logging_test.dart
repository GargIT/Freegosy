import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:freegosy/core/emulator/game_launch_service.dart';
import 'package:freegosy/core/emulator/strategies/pcsx2_strategy.dart';
import 'package:freegosy/core/emulator/strategy_registry.dart';
import 'package:freegosy/core/romm/romm_models.dart';
import 'package:freegosy/core/romm/romm_service.dart';
import 'package:freegosy/core/save/backup_repository.dart';
import 'package:freegosy/core/save/backup_service.dart';
import 'package:freegosy/core/save/save_sync_service.dart';
import 'package:freegosy/core/save/state_sync_capable.dart';
import 'package:freegosy/core/save/state_sync_service.dart';
import 'package:path/path.dart' as p;

import '../helpers/fake_romm_states_api.dart';
import '../helpers/pcsx2_test_env.dart';

/// PCSX2 as far as launching goes, but without state auto-load support.
class _NoAutoLoadStrategy extends Pcsx2Strategy {
  _NoAutoLoadStrategy(super.directoryService);

  @override
  bool get supportsStateAutoLoad => false;
}

/// Claims auto-load support under an emulator id whose save strategy cannot
/// name a state (DuckStation's is not StateSyncCapable).
class _IncapableSaveStrategyEmulator extends Pcsx2Strategy {
  _IncapableSaveStrategyEmulator(super.directoryService);

  @override
  String get emulatorId => 'duckstation';
}

/// Captures the debugPrints of the current test that start with [tag], in order
/// (other components log during a launch too).
List<String> _captureLogs(String tag) {
  final logs = <String>[];
  final old = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) {
    if (message != null && message.startsWith(tag)) logs.add(message);
  };
  addTearDown(() => debugPrint = old);
  return logs;
}

void main() {
  late Directory base;
  late Pcsx2TestEnv env;
  late String romPath;
  final game = Game(id: '42', name: 'Ico (SCUS-97113)', platformSlug: 'ps2', fileSize: 0);

  GameLaunchService buildService({StateSyncService? stateSync}) {
    final registry = StrategyRegistry(env.directoryService, env.prefs);
    final rommService = RommService(
      RomMConfig(baseUrl: 'https://romm.example.com', username: '', password: '', apiKey: 'k'),
      skipConnectivityCheck: true,
    );
    return GameLaunchService(
      directoryService: env.directoryService,
      strategyRegistry: registry,
      saveSyncService: SaveSyncService(rommService, env.directoryService, registry, env.prefs),
      backupService: BackupService(),
      backupRepository: BackupRepository(),
      prefs: env.prefs,
      stateSyncService: stateSync,
    );
  }

  File writeResumeState() =>
      File(p.join(env.statesDir, 'SCUS-97113 (A1B2C3D4).resume.p2s'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(List.filled(200, 7));

  GameSession session() => GameSession(
        process: null,
        sessionStart: DateTime(2026, 1, 1),
        emulatorId: 'pcsx2',
        activityTrackerFuture: Future.value(null),
      );

  setUp(() async {
    base = await Directory.systemTemp.createTemp('launch_logging');
    env = await Pcsx2TestEnv.create(base);
    romPath = p.join(base.path, 'Ico (SCUS-97113).iso');
  });

  tearDown(() => base.delete(recursive: true));

  group('autoLoadStatePath logs its outcome', () {
    test('will load the resume state', () async {
      final resume = writeResumeState();
      await env.prefs.setBool(stateAutoLoadKey('pcsx2'), true);
      final logs = _captureLogs('[AutoLoad]');

      await buildService().autoLoadStatePath(game, romPath, Pcsx2Strategy(env.directoryService));

      expect(logs, ['[AutoLoad] will load ${resume.path}']);
    });

    test('off for the emulator', () async {
      writeResumeState();
      final logs = _captureLogs('[AutoLoad]');

      await buildService().autoLoadStatePath(game, romPath, Pcsx2Strategy(env.directoryService));

      expect(logs, ["[AutoLoad] off for 'pcsx2'"]);
    });

    test('not supported by the emulator', () async {
      await env.prefs.setBool(stateAutoLoadKey('pcsx2'), true);
      final logs = _captureLogs('[AutoLoad]');

      await buildService()
          .autoLoadStatePath(game, romPath, _NoAutoLoadStrategy(env.directoryService));

      expect(logs, ["[AutoLoad] not supported by 'pcsx2'"]);
    });

    test('not supported when the emulator has no state-capable save strategy', () async {
      await env.prefs.setBool(stateAutoLoadKey('duckstation'), true);
      final logs = _captureLogs('[AutoLoad]');

      await buildService().autoLoadStatePath(
          game, romPath, _IncapableSaveStrategyEmulator(env.directoryService));

      expect(logs, [
        "[AutoLoad] not supported by 'duckstation' (its save strategy cannot name a state)",
      ]);
    });

    test('no resume state for the game', () async {
      await env.prefs.setBool(stateAutoLoadKey('pcsx2'), true);
      final logs = _captureLogs('[AutoLoad]');

      await buildService().autoLoadStatePath(game, romPath, Pcsx2Strategy(env.directoryService));

      expect(logs, ['[AutoLoad] no resume state for Ico (SCUS-97113)']);
    });
  });

  group('pushStatesAfterExit logs', () {
    test('that it was skipped when there is no state sync service', () async {
      final logs = _captureLogs('[StateSync]');

      final conflicts = await buildService().pushStatesAfterExit(session(), game, romPath);

      expect(conflicts, 0);
      expect(logs, ['[StateSync] post-exit push skipped: state sync service not available']);
    });

    test('that it ran, before the service reports what it did', () async {
      final stateSync = StateSyncService(FakeRommStatesApi(), env.prefs, (g, {emulatorId}) => null);
      final logs = _captureLogs('[StateSync]');

      await buildService(stateSync: stateSync).pushStatesAfterExit(session(), game, romPath);

      expect(logs.first, '[StateSync] post-exit push for Ico (SCUS-97113) (emulator pcsx2)');
      expect(logs, hasLength(2), reason: 'the service adds its own skip reason: $logs');
    });
  });
}
