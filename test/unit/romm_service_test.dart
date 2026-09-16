import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:freegosy/core/romm/romm_models.dart';
import 'package:freegosy/core/romm/romm_service.dart';

void main() {
  late RommService rommService;
  late Dio dio;
  late DioAdapter dioAdapter;

  const String testBaseUrl = 'https://romm.example.com';
  const String testApiKey = 'test_api_key_12345';

  setUp(() {
    dio = Dio(BaseOptions(baseUrl: testBaseUrl));
    dioAdapter = DioAdapter(dio: dio);
    
    final config = RomMConfig(
      baseUrl: testBaseUrl,
      username: '',
      password: '',
      apiKey: testApiKey,
    );
    
    rommService = RommService(config, dio: dio);
  });

  group('RommService API Authentication', () {
    test('sends API Key in both Authorization and X-Api-Key headers', () async {
      // Setup mock response
      dioAdapter.onGet(
        '/api/platforms',
        (server) => server.reply(200, {'items': []}),
        headers: {
          'Authorization': 'Bearer $testApiKey',
          'X-Api-Key': testApiKey,
        },
      );

      // Call the API
      final platforms = await rommService.getPlatforms();

      // Verify results
      expect(platforms, isEmpty);
    });

    test('getPlatforms correctly parses platforms list', () async {
      // Mock data
      final mockData = {
        'items': [
          {
            'id': 1,
            'name': 'Nintendo Switch',
            'slug': 'switch',
            'display_name': 'Switch',
            'rom_count': 10,
          },
          {
            'id': 2,
            'name': 'PlayStation 2',
            'slug': 'ps2',
            'display_name': 'PS2',
            'rom_count': 5,
          }
        ]
      };

      dioAdapter.onGet(
        '/api/platforms',
        (server) => server.reply(200, mockData),
      );

      final platforms = await rommService.getPlatforms();

      expect(platforms.length, 2);
      expect(platforms[0].id, 1);
      expect(platforms[0].name, 'Nintendo Switch');
      expect(platforms[1].slug, 'ps2');
    });

    test('getPlatforms throws DioException on error response', () async {
      dioAdapter.onGet(
        '/api/platforms',
        (server) => server.reply(401, {'message': 'Unauthorized'}),
      );

      expect(() => rommService.getPlatforms(), throwsA(isA<DioException>()));
    });
  });

  group('recordPlaySession', () {
    test('POSTs the sessions wrapped in the {device_id, sessions} envelope the server expects', () async {
      // recordPlaySession catches its own DioExceptions, so a request that
      // never matches a mocked route would otherwise pass silently. Capture
      // the actual outgoing request via a Dio interceptor instead — that's
      // independent of whether the mock adapter matched anything.
      RequestOptions? captured;
      dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
        if (options.path == '/api/play-sessions') captured = options;
        handler.next(options);
      }));
      dioAdapter.onPost(
        '/api/play-sessions',
        (server) => server.reply(201, {'results': [], 'created_count': 1, 'skipped_count': 0}),
        data: Matchers.any,
      );

      final start = DateTime.utc(2026, 1, 1, 10);
      final end = DateTime.utc(2026, 1, 1, 10, 5);
      await rommService.recordPlaySession(
        romId: '42',
        deviceId: 'device-1',
        startTime: start,
        endTime: end,
      );

      expect(captured, isNotNull);
      expect(captured!.data, {
        'device_id': 'device-1',
        'sessions': [
          {
            'rom_id': 42,
            'start_time': start.toIso8601String(),
            'end_time': end.toIso8601String(),
            'duration_ms': end.difference(start).inMilliseconds,
          }
        ],
      });
    });

    test('does not throw, and sends no request, for a non-numeric romId', () async {
      var requestSent = false;
      dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
        if (options.path == '/api/play-sessions') requestSent = true;
        handler.next(options);
      }));

      await rommService.recordPlaySession(
        romId: 'not-a-number',
        deviceId: 'device-1',
        startTime: DateTime.utc(2026, 1, 1, 10),
        endTime: DateTime.utc(2026, 1, 1, 10, 5),
      );

      expect(requestSent, isFalse);
    });
  });

  group('sendActivityHeartbeat', () {
    test('POSTs rom_id (as an int) and device_id to /api/activity/heartbeat', () async {
      RequestOptions? captured;
      dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
        if (options.path == '/api/activity/heartbeat') captured = options;
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

      await rommService.sendActivityHeartbeat(romId: '42', deviceId: 'device-1');

      expect(captured, isNotNull);
      expect(captured!.data, {'rom_id': 42, 'device_id': 'device-1'});
    });

    test('does not throw when the server errors (must fail silently)', () async {
      dioAdapter.onPost(
        '/api/activity/heartbeat',
        (server) => server.reply(500, {'message': 'error'}),
        data: Matchers.any,
      );

      await rommService.sendActivityHeartbeat(romId: '42', deviceId: 'device-1');
    });

    test('does not throw, and sends no request, for a non-numeric romId', () async {
      var requestSent = false;
      dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
        if (options.path == '/api/activity/heartbeat') requestSent = true;
        handler.next(options);
      }));

      await rommService.sendActivityHeartbeat(romId: 'not-a-number', deviceId: 'device-1');

      expect(requestSent, isFalse);
    });
  });

  group('clearActivityHeartbeat', () {
    test('DELETEs /api/activity/heartbeat with device_id as a query param', () async {
      RequestOptions? captured;
      dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
        if (options.path == '/api/activity/heartbeat') captured = options;
        handler.next(options);
      }));
      dioAdapter.onDelete(
        '/api/activity/heartbeat',
        (server) => server.reply(204, null),
      );

      await rommService.clearActivityHeartbeat(deviceId: 'device-1');

      expect(captured, isNotNull);
      expect(captured!.method, 'DELETE');
      expect(captured!.queryParameters, {'device_id': 'device-1'});
    });

    test('does not throw when the server errors (must fail silently)', () async {
      dioAdapter.onDelete(
        '/api/activity/heartbeat',
        (server) => server.reply(500, {'message': 'error'}),
      );

      await rommService.clearActivityHeartbeat(deviceId: 'device-1');
    });
  });

  group('activity heartbeat vs. connectivity heartbeat path handling', () {
    // /api/activity/heartbeat contains the substring '/api/heartbeat' (the
    // connectivity/capabilities poll path) — a naive `.contains()` check
    // conflates the two and silently drops activity-heartbeat retries.
    test('a transient (connection-level) failure on /api/activity/heartbeat is retried, unlike /api/heartbeat', () async {
      // A plain error *response* (e.g. 500) is DioExceptionType.badResponse,
      // which is never retried regardless of path — use a connection-level
      // error instead, the case the retry logic actually targets.
      var attempts = 0;
      dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
        if (options.path == '/api/activity/heartbeat') attempts++;
        handler.next(options);
      }));
      dioAdapter.onPost(
        '/api/activity/heartbeat',
        (server) => server.throws(
          0,
          DioException(requestOptions: RequestOptions(path: '/api/activity/heartbeat'), type: DioExceptionType.connectionError),
        ),
        data: Matchers.any,
      );

      await rommService.sendActivityHeartbeat(romId: '42', deviceId: 'device-1');

      expect(attempts, greaterThan(1));
    });
  });
}
