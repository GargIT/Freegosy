import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:freegosy/core/emulator/game_launch_service.dart';
import 'package:freegosy/core/emulator/strategies/pcsx2_strategy.dart';
import 'package:freegosy/core/emulator/strategy_registry.dart';
import 'package:freegosy/core/romm/romm_models.dart';
import 'package:freegosy/core/romm/romm_service.dart';
import 'package:freegosy/core/save/backup_repository.dart';
import 'package:freegosy/core/save/backup_service.dart';
import 'package:freegosy/core/save/save_sync_service.dart';
import 'package:freegosy/core/save/save_strategy.dart';
import 'package:freegosy/core/save/state_sync_capable.dart';
import 'package:freegosy/core/storage/directory_service.dart';
import 'package:path/path.dart' as p;

import '../helpers/pcsx2_test_env.dart';

/// Records which launch methods GameLaunchService calls and the extra
/// arguments each got, then optionally fails like a missing emulator. The
/// handle launch returns no process, so the fire-and-forget launch follows.
class _RecordingStrategy extends Pcsx2Strategy {
  _RecordingStrategy(super.directoryService, {this.failWith});

  final Object? failWith;
  final calls = <String>[];
  final extraArgsSeen = <List<String>>[];

  @override
  Future<Process?> launchWithHandle(Game game, String romPath) async {
    calls.add('launchWithHandle');
    if (failWith != null) throw failWith!;
    return null;
  }

  @override
  Future<void> launch(Game game, String romPath) async {
    calls.add('launch');
  }

  @override
  Future<Process?> launchWithHandleAndExtraArgs(Game game, String romPath,
      {List<String> extraArgs = const []}) async {
    calls.add('launchWithHandleAndExtraArgs');
    extraArgsSeen.add(extraArgs);
    if (failWith != null) throw failWith!;
    return null;
  }

  @override
  Future<void> launchWithExtraArgs(Game game, String romPath,
      {List<String> extraArgs = const []}) async {
    calls.add('launchWithExtraArgs');
    extraArgsSeen.add(extraArgs);
  }
}

/// PCSX2 as far as launching goes, but without state auto-load support.
class _NoAutoLoadStrategy extends Pcsx2Strategy {
  _NoAutoLoadStrategy(super.directoryService);

  @override
  bool get supportsStateAutoLoad => false;
}

/// [_NoAutoLoadStrategy] that records which launch methods were called.
class _PlainRecordingNoAutoLoadStrategy extends _NoAutoLoadStrategy {
  _PlainRecordingNoAutoLoadStrategy(super.directoryService);

  final calls = <String>[];

  @override
  Future<Process?> launchWithHandle(Game game, String romPath) async {
    calls.add('launchWithHandle');
    return null;
  }

  @override
  Future<void> launch(Game game, String romPath) async {
    calls.add('launch');
  }
}

/// Claims auto-load support under an emulator id whose save strategy cannot
/// name a state (DuckStation's is not StateSyncCapable).
class _IncapableSaveStrategyEmulator extends Pcsx2Strategy {
  _IncapableSaveStrategyEmulator(super.directoryService);

  @override
  String get emulatorId => 'duckstation';
}

/// One call the emulator launcher made: which method, for which ROM, and the
/// command-line arguments it would have started the emulator with.
class _LaunchCall {
  _LaunchCall(this.method, this.romPath, this.args);

  final String method;
  final String romPath;
  final List<String> args;
}

/// Records every launch instead of starting a process; the handle launch
/// returns no process, so the fire-and-forget launch follows it.
class _RecordingDirectoryService extends DirectoryService {
  _RecordingDirectoryService(super.prefs);

  final calls = <_LaunchCall>[];

  /// The arguments of every launch call made for [romPath].
  List<List<String>> argsFor(String romPath) => [
        for (final call in calls)
          if (call.romPath == p.absolute(p.normalize(romPath))) call.args,
      ];

  @override
  Future<Process?> launchGameWithHandle(
      Game game, String romPath, String emulatorId, String exePath,
      {List<String> args = const []}) async {
    calls.add(_LaunchCall('launchGameWithHandle', romPath, args));
    return null;
  }

  @override
  Future<void> launchGame(Game game, String romPath, String emulatorId, String exePath,
      {List<String> args = const []}) async {
    calls.add(_LaunchCall('launchGame', romPath, args));
  }
}

/// ONE shared PCSX2 strategy, like the registry hands out, whose first
/// [gatedCalls] `findExecutable` calls park until the test releases them. That
/// is the gap between resolving a launch's state and starting the emulator, in
/// which a second launch of the same emulator can run.
class _GatedFindStrategy extends Pcsx2Strategy {
  _GatedFindStrategy(super.directoryService, {required int gatedCalls})
      : gates = List.generate(gatedCalls, (_) => Completer<void>()),
        entered = List.generate(gatedCalls, (_) => Completer<void>());

  final List<Completer<void>> gates;
  final List<Completer<void>> entered;
  int _findCalls = 0;

  @override
  Future<String?> findExecutable() async {
    final index = _findCalls++;
    if (index < gates.length) {
      entered[index].complete();
      await gates[index].future;
    }
    return p.join(Directory.systemTemp.path, 'pcsx2', 'pcsx2-qt.exe');
  }
}

/// A SaveSyncService whose strategy lookup fails.
class _ThrowingLookupSaveSync extends SaveSyncService {
  _ThrowingLookupSaveSync(super.rommService, super.directoryService, super.registry, super.prefs);

  @override
  SaveStrategy? getStrategyForGame(Game game, {String? emulatorId}) =>
      throw StateError('lookup exploded');
}

void main() {
  late Directory base;
  late Pcsx2TestEnv env;
  late GameLaunchService service;
  late String romPath;
  final game = Game(id: '42', name: 'Ico (SCUS-97113)', platformSlug: 'ps2', fileSize: 0);

  GameLaunchService buildService(
      SaveSyncService Function(RommService, StrategyRegistry) saveSync) {
    final registry = StrategyRegistry(env.directoryService, env.prefs);
    final rommService = RommService(
      RomMConfig(baseUrl: 'https://romm.example.com', username: '', password: '', apiKey: 'k'),
      skipConnectivityCheck: true,
    );
    return GameLaunchService(
      directoryService: env.directoryService,
      strategyRegistry: registry,
      saveSyncService: saveSync(rommService, registry),
      backupService: BackupService(),
      backupRepository: BackupRepository(),
      prefs: env.prefs,
    );
  }

  File writeResume(String serial, String crc) =>
      File(p.join(env.statesDir, '$serial ($crc).resume.p2s'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(List.filled(200, 7));

  File writeResumeState() => writeResume('SCUS-97113', 'A1B2C3D4');

  Future<void> switchOn([String emulatorId = 'pcsx2']) =>
      env.prefs.setBool(stateAutoLoadKey(emulatorId), true);

  setUp(() async {
    base = await Directory.systemTemp.createTemp('autoload_launch');
    env = await Pcsx2TestEnv.create(base);
    romPath = p.join(base.path, 'Ico (SCUS-97113).iso');
    service = buildService((romm, registry) =>
        SaveSyncService(romm, env.directoryService, registry, env.prefs));
  });

  tearDown(() => base.delete(recursive: true));

  group('autoLoadStatePath', () {
    test('is the resume state when the switch is on', () async {
      final resume = writeResumeState();
      await switchOn();

      expect(await service.autoLoadStatePath(game, romPath, Pcsx2Strategy(env.directoryService)),
          resume.path);
    });

    test('is null when the switch is off (the default), even with a resume state', () async {
      writeResumeState();

      expect(await service.autoLoadStatePath(game, romPath, Pcsx2Strategy(env.directoryService)),
          isNull);
    });

    test('is null for an emulator that does not support auto-load, even if switched on', () async {
      writeResumeState();
      await switchOn();

      expect(await service.autoLoadStatePath(game, romPath, _NoAutoLoadStrategy(env.directoryService)),
          isNull);
    });

    test('is null when the emulator has no state-capable save strategy', () async {
      writeResumeState();
      await switchOn('duckstation');

      expect(
          await service.autoLoadStatePath(
              game, romPath, _IncapableSaveStrategyEmulator(env.directoryService)),
          isNull);
    });

    test('is null when the game has no resume state', () async {
      await switchOn();

      expect(await service.autoLoadStatePath(game, romPath, Pcsx2Strategy(env.directoryService)),
          isNull);
    });

    test('is null, not an error, when the stored switch has the wrong type', () async {
      writeResumeState();
      await env.prefs.setString(stateAutoLoadKey('pcsx2'), 'yes');

      expect(await service.autoLoadStatePath(game, romPath, Pcsx2Strategy(env.directoryService)),
          isNull);
    });

    test('is null, not an error, when looking the state up fails', () async {
      writeResumeState();
      await switchOn();
      final failing = buildService((romm, registry) =>
          _ThrowingLookupSaveSync(romm, env.directoryService, registry, env.prefs));

      expect(await failing.autoLoadStatePath(game, romPath, Pcsx2Strategy(env.directoryService)),
          isNull);
    });
  });

  group('launch', () {
    test('uses the extra-args launch methods, with the state arguments, when a state exists', () async {
      final resume = writeResumeState();
      await switchOn();
      final strategy = _RecordingStrategy(env.directoryService);

      await service.launch(game, romPath, strategy);

      expect(strategy.calls, ['launchWithHandleAndExtraArgs', 'launchWithExtraArgs'],
          reason: 'the handle launch, then the fire-and-forget fallback');
      expect(strategy.extraArgsSeen, [
        ['-statefile', resume.path],
        ['-statefile', resume.path],
      ], reason: 'the fallback must keep the state too');
    });

    test('a throwing launch with a state still rethrows', () async {
      writeResumeState();
      await switchOn();
      final strategy = _RecordingStrategy(env.directoryService,
          failWith: Exception('PCSX2 not found. Please download it first.'));

      await expectLater(service.launch(game, romPath, strategy), throwsException);

      expect(strategy.calls, ['launchWithHandleAndExtraArgs']);
    });

    test('a throwing launch with a state still stops the activity tracker', () async {
      writeResumeState();
      await switchOn();
      await env.prefs.setString('romm_device_id', 'device-1');
      var heartbeatCount = 0;
      var clearCount = 0;
      const baseUrl = 'https://romm.example.com';
      final dio = Dio(BaseOptions(baseUrl: baseUrl));
      final adapter = DioAdapter(dio: dio);
      dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
        if (options.path == '/api/activity/heartbeat') {
          if (options.method == 'POST') heartbeatCount++;
          if (options.method == 'DELETE') clearCount++;
        }
        handler.next(options);
      }));
      adapter.onGet('/api/heartbeat', (server) => server.reply(200, {'SYSTEM': {'VERSION': '4.9.0'}}));
      adapter.onPost('/api/activity/heartbeat', (server) => server.reply(200, {}), data: Matchers.any);
      adapter.onDelete('/api/activity/heartbeat', (server) => server.reply(204, null));
      final rommService = RommService(
        RomMConfig(baseUrl: baseUrl, username: '', password: '', apiKey: 'key'),
        dio: dio,
        skipConnectivityCheck: true,
      );
      final registry = StrategyRegistry(env.directoryService, env.prefs);
      final tracked = GameLaunchService(
        directoryService: env.directoryService,
        strategyRegistry: registry,
        saveSyncService: SaveSyncService(rommService, env.directoryService, registry, env.prefs),
        backupService: BackupService(),
        backupRepository: BackupRepository(),
        prefs: env.prefs,
        rommService: rommService,
      );
      final strategy = _RecordingStrategy(env.directoryService,
          failWith: Exception('PCSX2 not found. Please download it first.'));

      await expectLater(tracked.launch(game, romPath, strategy), throwsException);

      expect(heartbeatCount, 1, reason: 'the tracker started before the launch attempt');
      expect(clearCount, 1, reason: 'a failed launch must not leave the session showing as active');
    });

    test('uses the plain launch methods when the switch is off', () async {
      writeResumeState();
      final strategy = _RecordingStrategy(env.directoryService);

      await service.launch(game, romPath, strategy);

      expect(strategy.calls, ['launchWithHandle', 'launch']);
      expect(strategy.extraArgsSeen, isEmpty);
    });

    test('uses the plain launch methods when the game has no resume state', () async {
      await switchOn(); // no resume file on disk
      final strategy = _RecordingStrategy(env.directoryService);

      await service.launch(game, romPath, strategy);

      expect(strategy.calls, ['launchWithHandle', 'launch']);
      expect(strategy.extraArgsSeen, isEmpty);
    });

    test('uses the plain launch methods for an emulator without auto-load, even if switched on', () async {
      writeResumeState();
      await switchOn();
      final strategy = _PlainRecordingNoAutoLoadStrategy(env.directoryService);

      await service.launch(game, romPath, strategy);

      expect(strategy.calls, ['launchWithHandle', 'launch']);
    });

    test('keeps no state on the strategy: a later plain launch gets no -statefile', () async {
      final resume = writeResumeState();
      await switchOn();
      final recorder = _RecordingDirectoryService(env.prefs);
      final strategy = _GatedFindStrategy(recorder, gatedCalls: 0);

      await service.launch(game, romPath, strategy);
      expect(recorder.argsFor(romPath), everyElement(contains(resume.path)),
          reason: 'sanity: the first launch did load the state');
      recorder.calls.clear();
      await strategy.launchWithHandle(game, romPath);
      await strategy.launch(game, romPath);

      expect(recorder.argsFor(romPath), [
        ['-batch', '-fullscreen'],
        ['-batch', '-fullscreen'],
      ]);
    });

    test('still launches when the state lookup fails', () async {
      writeResumeState();
      await switchOn();
      final failing = buildService((romm, registry) =>
          _ThrowingLookupSaveSync(romm, env.directoryService, registry, env.prefs));
      final strategy = _RecordingStrategy(env.directoryService);

      final session = await failing.launch(game, romPath, strategy);

      expect(session.emulatorId, 'pcsx2');
      expect(strategy.calls, ['launchWithHandle', 'launch']);
    });
  });

  group('overlapping launches of the same emulator', () {
    final gameA = Game(id: '42', name: 'Ico (SCUS-97113)', platformSlug: 'ps2', fileSize: 0);
    final gameB = Game(id: '43', name: 'Gran Turismo 4 (SLUS-20312)', platformSlug: 'ps2', fileSize: 0);
    late String romA;
    late String romB;
    late _RecordingDirectoryService recorder;
    late _GatedFindStrategy strategy;

    Future<void> setUpLaunches({required int gatedCalls}) async {
      romA = p.join(base.path, 'Ico (SCUS-97113).iso');
      romB = p.join(base.path, 'Gran Turismo 4 (SLUS-20312).iso');
      recorder = _RecordingDirectoryService(env.prefs);
      strategy = _GatedFindStrategy(recorder, gatedCalls: gatedCalls);
      await switchOn();
    }

    List<String> withState(File state) => ['-batch', '-fullscreen', '-statefile', state.path];

    test('the first launch keeps its own state while a second launch runs to completion', () async {
      final stateA = writeResume('SCUS-97113', 'A1B2C3D4');
      final stateB = writeResume('SLUS-20312', 'B2C3D4E5');
      await setUpLaunches(gatedCalls: 1);

      final launchA = service.launch(gameA, romA, strategy);
      await strategy.entered[0].future; // A has resolved its state, not started yet
      await service.launch(gameB, romB, strategy);
      strategy.gates[0].complete();
      await launchA;

      expect(recorder.argsFor(romA), everyElement(withState(stateA)),
          reason: "A must start with its own state, not B's and not none");
      expect(recorder.argsFor(romA), isNotEmpty);
      expect(recorder.argsFor(romB), everyElement(withState(stateB)));
      expect(recorder.argsFor(romB), isNotEmpty);
    });

    test('the first launch is not left without a state when the second game has none', () async {
      final stateA = writeResume('SCUS-97113', 'A1B2C3D4');
      await setUpLaunches(gatedCalls: 1);

      final launchA = service.launch(gameA, romA, strategy);
      await strategy.entered[0].future;
      await service.launch(gameB, romB, strategy);
      strategy.gates[0].complete();
      await launchA;

      expect(recorder.argsFor(romA), everyElement(withState(stateA)),
          reason: "B's launch must not clear A's state");
      expect(recorder.argsFor(romA), isNotEmpty);
      expect(recorder.argsFor(romB), everyElement(['-batch', '-fullscreen']));
      expect(recorder.argsFor(romB), isNotEmpty);
    });

    test("the first launch never starts with the second game's state", () async {
      final stateA = writeResume('SCUS-97113', 'A1B2C3D4');
      final stateB = writeResume('SLUS-20312', 'B2C3D4E5');
      await setUpLaunches(gatedCalls: 2);

      final launchA = service.launch(gameA, romA, strategy);
      await strategy.entered[0].future;
      final launchB = service.launch(gameB, romB, strategy);
      await strategy.entered[1].future; // both have resolved their states
      strategy.gates[0].complete();
      await launchA;
      strategy.gates[1].complete();
      await launchB;

      expect(recorder.argsFor(romA), everyElement(withState(stateA)),
          reason: "A must not be started with B's resume state");
      expect(recorder.argsFor(romA), isNotEmpty);
      expect(recorder.argsFor(romB), everyElement(withState(stateB)));
      expect(recorder.argsFor(romB), isNotEmpty);
    });
  });
}
