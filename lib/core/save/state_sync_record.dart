import 'dart:convert';
import '../storage/app_preferences.dart';

/// What we remember about one state file after syncing it with RomM.
///
/// Metadata only — no file copies. [lastSyncedHash] is the md5 of the local
/// bytes at the last sync, so "did the local file change since" is a hash
/// compare; [serverUpdatedAt] is compared for equality only (RomM bumps it on
/// rescans, so it never orders anything).
class StateSyncRecord {
  final int? rommStateId;
  final String? lastSyncedHash;
  final String? serverUpdatedAt;

  /// Both sides changed and the user hasn't chosen yet. While set, push skips
  /// the file and pull re-reports it.
  final bool conflict;

  const StateSyncRecord({
    this.rommStateId,
    this.lastSyncedHash,
    this.serverUpdatedAt,
    this.conflict = false,
  });

  /// False for a placeholder that only carries a conflict flag (a slot that
  /// was never synced against the server state it collided with).
  bool get hasSynced => lastSyncedHash != null;

  StateSyncRecord copyWith({bool? conflict}) => StateSyncRecord(
        rommStateId: rommStateId,
        lastSyncedHash: lastSyncedHash,
        serverUpdatedAt: serverUpdatedAt,
        conflict: conflict ?? this.conflict,
      );

  Map<String, dynamic> toJson() => {
        'id': rommStateId,
        'hash': lastSyncedHash,
        'updatedAt': serverUpdatedAt,
        'conflict': conflict,
      };

  factory StateSyncRecord.fromJson(Map<String, dynamic> json) => StateSyncRecord(
        rommStateId: (json['id'] as num?)?.toInt(),
        lastSyncedHash: json['hash'] as String?,
        serverUpdatedAt: json['updatedAt'] as String?,
        conflict: json['conflict'] == true,
      );
}

/// Persists one JSON map of [StateSyncRecord]s per game, keyed by state file
/// name, in [AppPreferences] (the same store save sync uses for its hashes).
class StateRecordStore {
  final AppPreferences _prefs;

  StateRecordStore(this._prefs);

  static String keyFor(String gameId) => 'state_sync_records_$gameId';

  Map<String, StateSyncRecord> load(String gameId) {
    final raw = _prefs.getString(keyFor(gameId));
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map((name, value) =>
          MapEntry(name, StateSyncRecord.fromJson(value as Map<String, dynamic>)));
    } catch (_) {
      // Corrupt entry: start fresh. Worst case the next sync re-links states.
      return {};
    }
  }

  Future<void> save(String gameId, Map<String, StateSyncRecord> records) async {
    if (records.isEmpty) {
      await _prefs.remove(keyFor(gameId));
      return;
    }
    await _prefs.setString(
      keyFor(gameId),
      jsonEncode(records.map((name, record) => MapEntry(name, record.toJson()))),
    );
  }
}
