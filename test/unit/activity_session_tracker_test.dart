import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:freegosy/core/romm/activity_session_tracker.dart';
import 'package:freegosy/core/romm/romm_models.dart';
import 'package:freegosy/core/romm/romm_service.dart';

/// Regression coverage for issue #93: Freegosy should let RomM's real-time
/// "active sessions" board know when a game starts/stops, via periodic
/// heartbeats while playing and an explicit clear on stop.
void main() {
  late RommService rommService;
  late Dio dio;
  late DioAdapter dioAdapter;
  late int heartbeatCount;
  late int clearCount;

  const testBaseUrl = 'https://romm.example.com';

  setUp(() {
    dio = Dio(BaseOptions(baseUrl: testBaseUrl));
    dioAdapter = DioAdapter(dio: dio);
    heartbeatCount = 0;
    clearCount = 0;

    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      if (options.path == '/api/activity/heartbeat') {
        if (options.method == 'POST') heartbeatCount++;
        if (options.method == 'DELETE') clearCount++;
      }
      handler.next(options);
    }));

    dioAdapter.onPost(
      '/api/activity/heartbeat',
      (server) => server.reply(200, {
        'user_id': 1,
        'username': 'u',
        'avatar_path': '',
        'rom_id': 42,
        'rom_name': 'Game',
        'platform_slug': 'nds',
        'platform_name': 'Nintendo DS',
        'device_id': 'device-1',
        'device_type': 'freegosy',
        'started_at': DateTime.now().toIso8601String(),
      }),
      data: Matchers.any,
    );
    dioAdapter.onDelete('/api/activity/heartbeat', (server) => server.reply(204, null));

    rommService = RommService(
      RomMConfig(baseUrl: testBaseUrl, username: '', password: '', apiKey: 'key'),
      dio: dio,
      skipConnectivityCheck: true,
    );
  });

  group('ActivitySessionTracker.start', () {
    test('sends an immediate heartbeat', () async {
      final tracker = ActivitySessionTracker(rommService, heartbeatInterval: const Duration(seconds: 30));

      await tracker.start(romId: '42', deviceId: 'device-1');

      expect(heartbeatCount, 1);
    });

    test('repeats the heartbeat after each interval elapses', () async {
      final tracker = ActivitySessionTracker(rommService, heartbeatInterval: const Duration(milliseconds: 20));

      await tracker.start(romId: '42', deviceId: 'device-1');
      await Future.delayed(const Duration(milliseconds: 70));
      await tracker.stop();

      // 1 immediate + at least 2 periodic ticks in 70ms at a 20ms interval.
      expect(heartbeatCount, greaterThanOrEqualTo(3));
    });

    test('isActive is true once started', () async {
      final tracker = ActivitySessionTracker(rommService, heartbeatInterval: const Duration(seconds: 30));
      expect(tracker.isActive, isFalse);

      await tracker.start(romId: '42', deviceId: 'device-1');

      expect(tracker.isActive, isTrue);
    });
  });

  group('ActivitySessionTracker.stop', () {
    test('clears the active session', () async {
      final tracker = ActivitySessionTracker(rommService, heartbeatInterval: const Duration(seconds: 30));
      await tracker.start(romId: '42', deviceId: 'device-1');

      await tracker.stop();

      expect(clearCount, 1);
    });

    test('stops further periodic heartbeats', () async {
      final tracker = ActivitySessionTracker(rommService, heartbeatInterval: const Duration(milliseconds: 20));
      await tracker.start(romId: '42', deviceId: 'device-1');
      await tracker.stop();
      final countAtStop = heartbeatCount;

      await Future.delayed(const Duration(milliseconds: 60));

      expect(heartbeatCount, countAtStop);
    });

    test('isActive is false after stopping', () async {
      final tracker = ActivitySessionTracker(rommService, heartbeatInterval: const Duration(seconds: 30));
      await tracker.start(romId: '42', deviceId: 'device-1');

      await tracker.stop();

      expect(tracker.isActive, isFalse);
    });

    test('is a no-op when the tracker was never started', () async {
      final tracker = ActivitySessionTracker(rommService, heartbeatInterval: const Duration(seconds: 30));

      await tracker.stop();

      expect(clearCount, 0);
    });
  });
}
