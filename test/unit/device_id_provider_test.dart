import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:freegosy/core/romm/romm_models.dart';
import 'package:freegosy/core/romm/romm_service.dart';
import 'package:freegosy/providers/romm_provider.dart';
import 'package:freegosy/providers/shared_prefs_provider.dart';

import 'device_id_provider_test.mocks.dart';

/// Regression coverage: `deviceIdProvider` holds the only call to
/// `RommService.registerDevice()` in the app, but nothing ever watched it —
/// so `romm_device_id` was never persisted, silently breaking every
/// device-gated feature (play-session tracking, activity sync for #93,
/// device save sync). These tests exercise the provider directly, the way
/// `FreegosyApp` now does by watching it at startup.
@GenerateMocks([RommService])
void main() {
  late MockRommService mockRommService;
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    mockRommService = MockRommService();
  });

  ProviderContainer buildContainer() {
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      rommServiceProvider.overrideWithValue(mockRommService),
    ]);
    addTearDown(container.dispose);
    return container;
  }

  test('registers a device and persists it when the server supports device sync', () async {
    when(mockRommService.fetchCapabilities()).thenAnswer((_) async => RommCapabilities(version: '4.9.0'));
    when(mockRommService.registerDevice(
      name: anyNamed('name'),
      platform: anyNamed('platform'),
      allowExisting: anyNamed('allowExisting'),
    )).thenAnswer((_) async => 'device-abc');

    final container = buildContainer();
    final deviceId = await container.read(deviceIdProvider.future);

    expect(deviceId, 'device-abc');
    expect(prefs.getString('romm_device_id'), 'device-abc');
    verify(mockRommService.registerDevice(
      name: anyNamed('name'),
      platform: anyNamed('platform'),
      allowExisting: anyNamed('allowExisting'),
    )).called(1);
  });

  test('does not register when the server is below 4.9 (no device sync support)', () async {
    when(mockRommService.fetchCapabilities()).thenAnswer((_) async => RommCapabilities(version: '4.8.1'));

    final container = buildContainer();
    final deviceId = await container.read(deviceIdProvider.future);

    expect(deviceId, isNull);
    expect(prefs.getString('romm_device_id'), isNull);
    verifyNever(mockRommService.registerDevice(
      name: anyNamed('name'),
      platform: anyNamed('platform'),
      allowExisting: anyNamed('allowExisting'),
    ));
  });

  test('reuses an already-persisted device id without re-registering', () async {
    SharedPreferences.setMockInitialValues({'romm_device_id': 'already-set'});
    prefs = await SharedPreferences.getInstance();
    when(mockRommService.fetchCapabilities()).thenAnswer((_) async => RommCapabilities(version: '4.9.0'));

    final container = buildContainer();
    final deviceId = await container.read(deviceIdProvider.future);

    expect(deviceId, 'already-set');
    verifyNever(mockRommService.registerDevice(
      name: anyNamed('name'),
      platform: anyNamed('platform'),
      allowExisting: anyNamed('allowExisting'),
    ));
  });
}
