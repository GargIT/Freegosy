import 'package:flutter_test/flutter_test.dart';
import 'package:freegosy/core/save/state_sync_record.dart';
import 'package:freegosy/core/storage/shared_preferences_app_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late SharedPreferencesAppPreferences prefs;
  late StateRecordStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = SharedPreferencesAppPreferences(await SharedPreferences.getInstance());
    store = StateRecordStore(prefs);
  });

  test('round-trips records per game', () async {
    await store.save('42', {
      'a.p2s': const StateSyncRecord(
          rommStateId: 7, lastSyncedHash: 'abc', serverUpdatedAt: '2026-01-01T00:00:00Z'),
      'b.p2s': const StateSyncRecord(rommStateId: 8, conflict: true),
    });

    final loaded = store.load('42');

    expect(loaded['a.p2s']!.rommStateId, 7);
    expect(loaded['a.p2s']!.lastSyncedHash, 'abc');
    expect(loaded['a.p2s']!.serverUpdatedAt, '2026-01-01T00:00:00Z');
    expect(loaded['a.p2s']!.conflict, isFalse);
    expect(loaded['b.p2s']!.conflict, isTrue);
    expect(store.load('43'), isEmpty, reason: 'records are scoped to the game');
  });

  test('hasSynced is true only once a hash has been recorded', () {
    expect(const StateSyncRecord(rommStateId: 1, conflict: true).hasSynced, isFalse);
    expect(const StateSyncRecord(rommStateId: 1, lastSyncedHash: 'h').hasSynced, isTrue);
  });

  test('copyWith(conflict:) keeps every other field', () {
    const record = StateSyncRecord(
        rommStateId: 7, lastSyncedHash: 'abc', serverUpdatedAt: 'u');

    final flagged = record.copyWith(conflict: true);

    expect(flagged.conflict, isTrue);
    expect(flagged.rommStateId, 7);
    expect(flagged.lastSyncedHash, 'abc');
    expect(flagged.serverUpdatedAt, 'u');
  });

  test('corrupt stored JSON loads as empty instead of throwing', () async {
    await prefs.setString(StateRecordStore.keyFor('42'), '{not json');

    expect(store.load('42'), isEmpty);
  });

  test('saving an empty map removes the key', () async {
    await store.save('42', {'a.p2s': const StateSyncRecord(rommStateId: 1, lastSyncedHash: 'h')});
    await store.save('42', {});

    expect(prefs.getString(StateRecordStore.keyFor('42')), isNull);
  });
}
