import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:freegosy/core/emulator/game_launch_service.dart';
import 'package:freegosy/core/emulator/strategies/pcsx2_strategy.dart';
import 'package:freegosy/core/emulator/strategy_registry.dart';
import 'package:freegosy/core/romm/romm_models.dart';
import 'package:freegosy/core/romm/romm_service.dart';
import 'package:freegosy/core/save/backup_repository.dart';
import 'package:freegosy/core/save/backup_service.dart';
import 'package:freegosy/core/save/save_sync_service.dart';
import 'package:freegosy/core/storage/directory_service.dart';
import 'package:freegosy/core/storage/shared_preferences_app_preferences.dart';

class _ThrowingLaunchStrategy extends Pcsx2Strategy {
  _ThrowingLaunchStrategy(super.directoryService);

  @override
  Future<Process?> launchWithHandle(Game game, String romPath) async {
    throw Exception('PCSX2 not found. Please download it first.');
  }
}

class _NoHandleStrategy extends Pcsx2Strategy {
  _NoHandleStrategy(super.directoryService);

  @override
  Future<Process?> launchWithHandle(Game game, String romPath) async => null;

  @override
  Future<void> launch(Game game, String romPath) async {}
}

void main() {
  late GameLaunchService service;
  late DirectoryService dirService;
  late _ThrowingLaunchStrategy strategy;
  late Game game;
  late int heartbeatCount;
  late int clearCount;

  setUp(() async {
    SharedPreferences.setMockInitialValues({'romm_device_id': 'device-1'});
    final prefs = SharedPreferencesAppPreferences(await SharedPreferences.getInstance());

    const baseUrl = 'https://romm.example.com';
    final dio = Dio(BaseOptions(baseUrl: baseUrl));
    final adapter = DioAdapter(dio: dio);
    heartbeatCount = 0;
    clearCount = 0;
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
    dirService = DirectoryService(prefs);
    final registry = StrategyRegistry(dirService, prefs);
    service = GameLaunchService(
      directoryService: dirService,
      strategyRegistry: registry,
      saveSyncService: SaveSyncService(rommService, dirService, registry, prefs),
      backupService: BackupService(),
      backupRepository: BackupRepository(),
      prefs: prefs,
      rommService: rommService,
    );
    strategy = _ThrowingLaunchStrategy(dirService);
    game = Game(id: '42', name: 'game', platformSlug: 'ps2', fileSize: 0);
  });

  test('launch() stops the activity tracker when the strategy throws (e.g. emulator not installed)', () async {
    await expectLater(service.launch(game, '/roms/game.chd', strategy), throwsException);

    expect(heartbeatCount, 1, reason: 'the tracker should have started before the launch attempt');
    expect(clearCount, 1, reason: 'a failed launch must not leave the session showing as active');
  });

  test('launch() stops the activity tracker on the fire-and-forget path (no process handle)', () async {
    final session = await service.launch(game, '/roms/game.chd', _NoHandleStrategy(dirService));

    expect(session.process, isNull);
    expect(heartbeatCount, 1);
    expect(clearCount, 1, reason: 'nothing else can stop a tracker for a launch with no exit signal');
  });
}
