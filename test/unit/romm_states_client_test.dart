import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:freegosy/core/romm/romm_models.dart';
import 'package:freegosy/core/romm/romm_service.dart';
import 'package:freegosy/core/romm/romm_state.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';

/// Fails every request with a connection error that carries the request's own
/// options, like Dio's real adapters do (the retry logic reads them back).
class _ConnectionLostAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    throw DioException.connectionError(
        requestOptions: options, reason: 'connection lost');
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  const baseUrl = 'https://romm.example.com';
  late RommService service;
  late Dio dio;
  late DioAdapter adapter;
  late Directory tmp;
  late File stateFile;

  /// Options of every request that reached the adapter, retries included.
  late List<RequestOptions> requests;

  setUp(() async {
    dio = Dio(BaseOptions(baseUrl: baseUrl));
    adapter = DioAdapter(dio: dio);
    requests = [];
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      requests.add(options);
      handler.next(options);
    }));
    service = RommService(
      RomMConfig(baseUrl: baseUrl, username: '', password: '', apiKey: 'key'),
      dio: dio,
      skipConnectivityCheck: true,
    );
    tmp = await Directory.systemTemp.createTemp('romm_states_client');
    stateFile = File('${tmp.path}/SCUS-97113 (A1B2C3D4).01.p2s')
      ..writeAsBytesSync(List.filled(256, 7));
  });

  tearDown(() async {
    // On Windows the mock adapter never drains the multipart file stream, so
    // the OS may still hold the file open. Cleanup is best-effort.
    try {
      await tmp.delete(recursive: true);
    } on FileSystemException {
      // Leaked temp dir under the OS temp folder; harmless.
    }
  });

  Map<String, dynamic> stateJson(int id, String name) => {
        'id': id,
        'rom_id': 42,
        'file_name': name,
        'updated_at': '2026-01-01T00:00:00Z',
      };

  test('listStates parses a bare list', () async {
    adapter.onGet(
      '/api/states',
      (server) => server.reply(200, [stateJson(7, 'a.p2s')]),
      queryParameters: {'rom_id': '42'},
    );

    final states = await service.listStates('42');

    expect(states, hasLength(1));
    expect(states.first.id, 7);
    expect(states.first.fileName, 'a.p2s');
    expect(states.first.updatedAt, '2026-01-01T00:00:00Z');
  });

  test('listStates parses an {items: [...]} envelope', () async {
    adapter.onGet(
      '/api/states',
      (server) => server.reply(200, {'items': [stateJson(8, 'b.p2s')]}),
      queryParameters: {'rom_id': '42'},
    );

    final states = await service.listStates('42');

    expect(states.single.id, 8);
  });

  test('uploadState POSTs a multipart stateFile with emulator=freegosy', () async {
    adapter.onPost(
      '/api/states',
      (server) => server.reply(200, stateJson(9, 'SCUS-97113 (A1B2C3D4).01.p2s')),
      data: Matchers.any,
      queryParameters: {'rom_id': '42', 'emulator': 'freegosy'},
    );

    final state = await service.uploadState('42', stateFile,
        fileName: 'SCUS-97113 (A1B2C3D4).01.p2s');

    expect(state.id, 9);
  });

  test('updateState PUTs to the state id', () async {
    adapter.onPut(
      '/api/states/7',
      (server) => server.reply(200, stateJson(7, 'a.p2s')),
      data: Matchers.any,
    );

    final state = await service.updateState(7, stateFile, fileName: 'a.p2s');

    expect(state.id, 7);
  });

  test('updateState maps a 404 to RommStateNotFoundException', () async {
    adapter.onPut(
      '/api/states/7',
      (server) => server.reply(404, {'detail': 'State not found'}),
      data: Matchers.any,
    );

    expect(
      () => service.updateState(7, stateFile, fileName: 'a.p2s'),
      throwsA(isA<RommStateNotFoundException>()),
    );
  });

  test('downloadState returns the raw bytes', () async {
    adapter.onGet(
      '/api/states/7/content',
      (server) => server.reply(200, Uint8List.fromList([1, 2, 3])),
    );

    final bytes = await service.downloadState(7);

    expect(bytes, Uint8List.fromList([1, 2, 3]));
  });

  test('downloadState maps a 404 to RommStateNotFoundException', () async {
    adapter.onGet(
      '/api/states/7/content',
      (server) => server.reply(404, {'detail': 'State not found'}),
    );

    expect(() => service.downloadState(7), throwsA(isA<RommStateNotFoundException>()));
  });

  group('transfer bounds', () {
    test('downloadState carries the 30 s inactivity timeout and the no-retry flag', () async {
      adapter.onGet(
        '/api/states/7/content',
        (server) => server.reply(200, Uint8List.fromList([1, 2, 3])),
      );

      await service.downloadState(7);

      expect(RommService.stateDownloadInactivityTimeout, const Duration(seconds: 30));
      final options = requests.single;
      expect(options.receiveTimeout, const Duration(seconds: 30));
      expect(options.extra['no_retry'], isTrue);
      expect(options.headers['Authorization'], 'Bearer key', reason: 'still authenticated');
      expect(options.responseType, ResponseType.bytes);
    });

    test('a failed download makes exactly one request', () async {
      dio.httpClientAdapter = _ConnectionLostAdapter();

      await expectLater(service.downloadState(7), throwsA(isA<DioException>()));

      expect(requests, hasLength(1), reason: 'the sync stops at the first failed download');
    });

    test('other requests are still retried after a connection error', () async {
      dio.httpClientAdapter = _ConnectionLostAdapter();

      await expectLater(service.listStates('42'), throwsA(isA<DioException>()));

      expect(requests, hasLength(3), reason: 'first attempt plus the two retries');
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('uploads and updates keep the 5 minute timeouts', () async {
      adapter.onPost(
        '/api/states',
        (server) => server.reply(200, stateJson(9, 'a.p2s')),
        data: Matchers.any,
        queryParameters: {'rom_id': '42', 'emulator': 'freegosy'},
      );
      adapter.onPut(
        '/api/states/7',
        (server) => server.reply(200, stateJson(7, 'a.p2s')),
        data: Matchers.any,
      );

      await service.uploadState('42', stateFile, fileName: 'a.p2s');
      await service.updateState(7, stateFile, fileName: 'a.p2s');

      expect(requests, hasLength(2));
      for (final options in requests) {
        expect(options.receiveTimeout, const Duration(minutes: 5));
        expect(options.sendTimeout, const Duration(minutes: 5));
        expect(options.extra['no_retry'], isNull);
      }
    });
  });
}
