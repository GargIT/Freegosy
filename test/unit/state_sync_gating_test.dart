import 'package:flutter_test/flutter_test.dart';
import 'package:freegosy/core/emulator/emulator_registry_data.dart';
import 'package:freegosy/core/emulator/strategy_registry.dart';
import 'package:freegosy/core/romm/romm_models.dart';
import 'package:freegosy/core/romm/romm_service.dart';
import 'package:freegosy/core/save/save_sync_service.dart';
import 'package:freegosy/core/save/state_sync_capable.dart';
import 'package:freegosy/core/storage/directory_service.dart';
import 'package:freegosy/core/storage/shared_preferences_app_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('every emulator advertising state sync has a StateSyncCapable save strategy', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = SharedPreferencesAppPreferences(await SharedPreferences.getInstance());
    final directoryService = DirectoryService(prefs);
    final registry = StrategyRegistry(directoryService, prefs);
    final saveSync = SaveSyncService(
      RommService(
        RomMConfig(baseUrl: 'https://romm.example.com', username: '', password: '', apiKey: 'k'),
        skipConnectivityCheck: true,
      ),
      directoryService,
      registry,
      prefs,
    );

    final advertising = <String>[];
    for (final definition in kEmulatorDefinitions) {
      final id = definition['id'] as String;
      final strategy = registry.getStrategyById(id);
      if (strategy == null || !strategy.supportsStateSync) continue;
      advertising.add(id);
      expect(saveSync.getStrategyForSlug(null, emulatorId: id), isA<StateSyncCapable>(),
          reason: '$id advertises supportsStateSync but its save strategy is not StateSyncCapable');
    }

    expect(advertising, ['pcsx2'], reason: 'PCSX2 is the only emulator with state sync so far');
  });

  test('every emulator that can load a state on launch has a StateSyncCapable save strategy', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = SharedPreferencesAppPreferences(await SharedPreferences.getInstance());
    final directoryService = DirectoryService(prefs);
    final registry = StrategyRegistry(directoryService, prefs);
    final saveSync = SaveSyncService(
      RommService(
        RomMConfig(baseUrl: 'https://romm.example.com', username: '', password: '', apiKey: 'k'),
        skipConnectivityCheck: true,
      ),
      directoryService,
      registry,
      prefs,
    );

    final advertising = <String>[];
    for (final definition in kEmulatorDefinitions) {
      final id = definition['id'] as String;
      final strategy = registry.getStrategyById(id);
      if (strategy == null || !strategy.supportsStateLoadOnLaunch) continue;
      advertising.add(id);
      expect(saveSync.getStrategyForSlug(null, emulatorId: id), isA<StateSyncCapable>(),
          reason: '$id advertises supportsStateLoadOnLaunch but its save strategy is not StateSyncCapable');
    }

    expect(advertising, ['pcsx2'], reason: 'PCSX2 is the only emulator that can load a state on launch so far');
  });

  test('emulators default to not loading a state on launch', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = SharedPreferencesAppPreferences(await SharedPreferences.getInstance());
    final registry = StrategyRegistry(DirectoryService(prefs), prefs);

    expect(registry.getStrategyById('duckstation')!.supportsStateLoadOnLaunch, isFalse);
    expect(registry.getStrategyById('retroarch')!.supportsStateLoadOnLaunch, isFalse);
  });

  test('emulators default to not supporting state sync', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = SharedPreferencesAppPreferences(await SharedPreferences.getInstance());
    final registry = StrategyRegistry(DirectoryService(prefs), prefs);

    expect(registry.getStrategyById('duckstation')!.supportsStateSync, isFalse);
    expect(registry.getStrategyById('retroarch')!.supportsStateSync, isFalse);
  });
}
