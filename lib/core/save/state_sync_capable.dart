import 'dart:io' as io;
import 'dart:typed_data';
import '../romm/romm_models.dart';
import 'save_strategy.dart';

/// Implemented by a [SaveStrategy] whose emulator's save states can be synced
/// through RomM's `/api/states` (see StateSyncService).
///
/// The strategy only answers *where* an emulator keeps a game's states and
/// *which* file names belong to the game. Hashing, transfers, safe writes and
/// conflict handling live in StateSyncService so every emulator gets the same
/// behaviour.
mixin StateSyncCapable on SaveStrategy {
  /// Directory holding [game]'s state files. May throw if the emulator's data
  /// folder cannot be resolved; the caller treats that as "skip state sync".
  Future<String> stateDirectory(Game game, String romPath);

  /// Predicate telling whether a state file name — local or from the server —
  /// belongs to [game], or null if the game cannot be identified (for example
  /// its serial could not be read from the ROM). It must reject names that
  /// contain path separators and backup/temp files.
  Future<bool Function(String fileName)?> stateFileMatcher(
      Game game, String romPath);

  /// Sanity check applied to bytes downloaded from RomM before they replace a
  /// local state. The default only rejects empty content.
  bool looksLikeValidState(Uint8List bytes) => bytes.isNotEmpty;

  /// The state file the emulator should load when [game] launches, for users
  /// who opted in to auto-loading a resume state; null means none (the
  /// default). Must never throw for a missing or unreadable state folder.
  Future<io.File?> autoLoadState(Game game, String romPath) async => null;
}

/// AppPreferences key of the per-emulator "auto-load resume state on launch"
/// opt-in (off by default, only honoured where the emulator supports it).
String stateAutoLoadKey(String emulatorId) => 'state_autoload_enabled_$emulatorId';
