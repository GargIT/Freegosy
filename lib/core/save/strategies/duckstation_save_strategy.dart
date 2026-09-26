import 'dart:io';
import 'dart:io' as io;
import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import '../../disc/serial_extraction_service.dart';
import '../../platform/platform_info.dart';
import '../../romm/romm_models.dart';
import '../../storage/app_preferences.dart';
import '../../storage/directory_service.dart';
import '../save_state_info.dart';
import '../save_strategy.dart';
import '../state_sync_capable.dart';
import 'duckstation_config.dart';
import 'duckstation_state_file.dart';

/// Save strategy for DuckStation (PlayStation 1).
/// Memcards: {dataDir}/memcards/*.mcd
/// States:   {dataDir}/savestates/{SERIAL}_{N|resume}.sav — synced separately
///           through [StateSyncCapable] / StateSyncService, not by this
///           strategy's save methods.
class DuckstationSaveStrategy extends SaveStrategy with StateSyncCapable {
  final DirectoryService _directoryService;
  final PlatformInfo _platform;
  final SerialExtractionService _serialExtractionService;
  final ZstdDecompressor? _zstd;

  /// PS1's `SYSTEM.CNF` boot line, e.g. `BOOT = cdrom:\SLES_035.08;1`. The
  /// `\s*=` right after `BOOT` keeps PS2's `BOOT2 =` line from matching.
  static final _bootLinePattern = RegExp(
      r'BOOT\s*=\s*cdrom[^:]*:\\?([A-Z]{4}[_-]\d{3}[.]\d{2})',
      caseSensitive: false);

  DuckstationSaveStrategy(this._directoryService, AppPreferences prefs,
      {PlatformInfo? platform,
      SerialExtractionService? serialExtractionService,
      ZstdDecompressor? zstd})
      : _platform = platform ?? PlatformInfo.current,
        _zstd = zstd,
        _serialExtractionService = serialExtractionService ??
            SerialExtractionService(_directoryService, prefs, platform: platform);

  @override
  String get strategyId => 'duckstation';

  /// Extracts the PS1 game serial (e.g. "SLES-03508") from the ROM. See
  /// [SerialExtractionService] for the filename/CHD/ISO extraction strategy.
  /// Returns null if the serial cannot be determined.
  Future<String?> _extractSerial(String romPath) => _serialExtractionService.extractSerial(
        romPath: romPath,
        bootLinePattern: _bootLinePattern,
        chdmanCandidates: [(emulatorId: 'duckstation', exeName: _getEmuExe())],
      );

  /// DuckStation's per-game state naming: `SERIAL_N.sav` or
  /// `SERIAL_resume.sav` (System::GetGameSaveStateFileName). The character
  /// class excludes path separators; `.sav.backup` doesn't match. The global
  /// slots (`savestate_N.sav`) aren't tied to a game and are never matched.
  static final _stateFilePattern = RegExp(r'^([A-Za-z0-9-]+)_(resume|\d{1,2})\.sav$');

  static String _serialKey(String serial) =>
      serial.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

  static RegExpMatch? _matchState(String fileName) {
    final match = _stateFilePattern.firstMatch(fileName);
    if (match == null || match.group(1)!.toLowerCase() == 'savestate') return null;
    return match;
  }

  @override
  Future<String> stateDirectory(Game game, String romPath) async =>
      p.join(await _getBaseDir(platformSlug: game.platformSlug), 'savestates');

  @override
  Future<bool Function(String fileName)?> stateFileMatcher(
      Game game, String romPath) async {
    final serial = await _extractSerial(romPath);
    if (serial == null) return null;
    final wanted = _serialKey(serial);
    return (String fileName) {
      final match = _matchState(fileName);
      return match != null && _serialKey(match.group(1)!) == wanted;
    };
  }

  @override
  bool looksLikeValidState(Uint8List bytes) => DuckstationStateFile.hasMagic(bytes);

  @override
  StateSlot slotOf(String fileName) {
    final match = _matchState(fileName);
    if (match == null) return UnknownStateSlot(fileName);
    final slot = match.group(2)!;
    return slot == 'resume' ? const AutoStateSlot() : NumberedStateSlot(int.parse(slot));
  }

  /// DuckStation records only its state format version, not the build that
  /// wrote the state: there is no emulator version to compare.
  @override
  Future<StateFileInfo> describeState(File file) async {
    final base = await super.describeState(file);
    final format = await DuckstationStateFile.readFormatVersion(file);
    return StateFileInfo(savedAt: base.savedAt, formatId: format?.toString());
  }

  @override
  Future<Uint8List?> stateScreenshot(File file) =>
      DuckstationStateFile.readScreenshot(file, zstd: _zstd);

  String _getEmuExe() {
    if (_platform.isWindows) return 'duckstation-qt-x64-ReleaseLTCG.exe';
    if (_platform.isMacOS) return 'DuckStation.app/Contents/MacOS/DuckStation';
    return 'duckstation-qt';
  }

  Future<String> _getBaseDir({String? platformSlug}) async {
    // 1. Check portable mode first (all platforms)
    //
    // DuckStation treats the install as portable when EITHER portable.txt OR
    // settings.ini exists next to the executable (upstream core.cpp):
    //   if (FileExists("portable.txt") || FileExists("settings.ini"))
    //     DataRoot = exe dir
    // Scoop installs and some portable builds only have settings.ini (created
    // on first run), so we must check both or we fall through to the wrong
    // directory and report "no saves" (issue #28).
    final exePath = await _directoryService.findEmulatorExecutable(
        'duckstation', _getEmuExe());
    if (exePath != null) {
      String emulatorDir = File(exePath).parent.path;
      if (_platform.isMacOS && exePath.contains('.app/Contents/MacOS/')) {
        emulatorDir = io.File(exePath).parent.parent.parent.parent.path;
      }
      final portableMarker = File(p.join(emulatorDir, 'portable.txt'));
      final settingsMarker = File(p.join(emulatorDir, 'settings.ini'));
      if (await portableMarker.exists() || await settingsMarker.exists()) {
        debugPrint('[DuckStation] portable mode detected via '
            '${await portableMarker.exists() ? "portable.txt" : "settings.ini"} → $emulatorDir');
        return emulatorDir;
      }
      debugPrint('[DuckStation] exe found at $exePath but no portable.txt/settings.ini — not portable');
    } else {
      debugPrint('[DuckStation] no duckstation exe found via DirectoryService');
    }

    // 2. Dynamic path resolution for macOS/Windows/Linux
    final String resolvedPath;
    if (_platform.isWindows) {
      final localAppData = _platform.environment['LOCALAPPDATA'] ?? '';
      resolvedPath = p.join(localAppData, 'DuckStation');
    } else {
      resolvedPath = await _directoryService.getEmulatorAppSupportDirectory('DuckStation', platformSlug: platformSlug);
    }

    debugPrint('[DuckStation] standard install base candidate: $resolvedPath');
    if (!await io.Directory(resolvedPath).exists()) {
      throw Exception('Save directory not found for DuckStation at $resolvedPath. Please launch DuckStation at least once to generate save data.');
    }
    return resolvedPath;
  }

  // ─── Memory cards ─────────────────────────────────────────────────────────
  //
  // DuckStation names a game's card by its "Memory Card Type" setting
  // (`[MemoryCards] CardNType`, overridable per game in
  // `gamesettings/<SERIAL>.ini`): `<serial>_N.mcd`, `<title>_N.mcd` (the
  // `saveName` in its own gamedb.yaml) or `<ROM file name>_N.mcd`, N being
  // the port. Freegosy reads that setting, uploads exactly those cards, and
  // restores a card under the name *this* PC's DuckStation will open, so PCs
  // set to different types still share the save. One card shared by every
  // game can't be synced per game (restoring it would roll back all other
  // games), so that setup blocks sync; see [saveSyncBlockedReason].

  static const _sharedCardMessage =
      'DuckStation uses one memory card shared by all games, so its saves '
      "can't be synced per game. To sync them, choose a \"Separate Card Per "
      "Game\" memory card type in DuckStation's settings.";
  static const _noCardMessage =
      'DuckStation has no memory card that keeps saves ("No Memory Card" or '
      '"Non-Persistent"), so there is nothing to sync.';

  Future<_CardSetup> _cardSetup(Game game, String romPath, {bool needSerial = true}) async {
    final baseDir = await _getBaseDir(platformSlug: game.platformSlug);
    final serial = needSerial ? await _extractSerial(romPath) : null;
    final globalIni = await _readIfExists(p.join(baseDir, 'settings.ini'));
    final gameIni =
        serial == null ? null : await _readIfExists(p.join(baseDir, 'gamesettings', '$serial.ini'));
    final config = DuckstationMemcardConfig.fromIni(globalIni, gameIni);
    final directory = config.directory;
    final memcardsDir = directory == null
        ? p.join(baseDir, 'memcards')
        : (p.isAbsolute(directory) ? directory : p.join(baseDir, directory));
    return _CardSetup(memcardsDir: memcardsDir, config: config, serial: serial);
  }

  static Future<String?> _readIfExists(String path) async {
    try {
      final file = File(path);
      return await file.exists() ? await file.readAsString() : null;
    } catch (e) {
      debugPrint('[DuckStation] cannot read $path: $e');
      return null;
    }
  }

  /// DuckStation's installed `resources` folder (holding gamedb.yaml), or
  /// null when it can't be found (e.g. inside an AppImage).
  Future<String?> _resourcesDir() async {
    final exePath = await _directoryService.findEmulatorExecutable('duckstation', _getEmuExe());
    if (exePath == null) return null;
    final exeDir = File(exePath).parent;
    for (final dir in [
      p.join(exeDir.path, 'resources'),
      if (_platform.isMacOS) p.join(exeDir.parent.path, 'Resources'),
    ]) {
      if (await File(p.join(dir, 'gamedb.yaml')).exists()) return dir;
    }
    return null;
  }

  /// The exact name (without `_N.mcd`) DuckStation gives [game]'s card of
  /// [type], or null when it can't be known: the serial couldn't be read,
  /// or (by title) the game database doesn't know the game.
  Future<String?> _cardName(_CardSetup setup, DuckstationCardType type, Game game, String romPath) async {
    switch (type) {
      case DuckstationCardType.perGameSerial:
        return setup.serial;
      case DuckstationCardType.perGameFileTitle:
        final title = await FileSystemEntity.isDirectory(romPath)
            ? getRomStem(game)
            : p.basenameWithoutExtension(romPath);
        return duckstationSafeFileName(title);
      case DuckstationCardType.perGameTitle:
        final serial = setup.serial;
        final resources = serial == null ? null : await _resourcesDir();
        if (serial == null || resources == null) return null;
        final title = await DuckstationGameDb.saveTitle(resources, serial,
            usePlaylistTitle: setup.config.usePlaylistTitle);
        return title == null ? null : duckstationSafeFileName(title);
      default:
        return null;
    }
  }

  /// [game]'s card for [port] on disk, or null when there is none.
  Future<File?> _localCard(_CardSetup setup, Game game, String romPath, int port) async {
    final type = setup.config.typeOf(port);
    final name = await _cardName(setup, type, game, romPath);
    if (name != null) {
      final file = File(p.join(setup.memcardsDir, '${name}_$port.mcd'));
      return await file.exists() ? file : null;
    }
    if (type == DuckstationCardType.perGameTitle) {
      debugPrint('[DuckStation]   title unknown to the game database — matching cards by name');
      return _cardByTitleWords(setup.memcardsDir, game, port);
    }
    debugPrint('[DuckStation]   serial unknown — no ${type.iniValue} card name for port $port');
    return null;
  }

  /// Fallback when the card title isn't known: the newest card for [port]
  /// whose name contains every word (3+ letters) of the ROM name without its
  /// tags. Word matching avoids "final fantasy vii" matching "... viii";
  /// multi-disc `.m3u` names like "Final Fantasy VII (USA).m3u" match
  /// "Final Fantasy VII_1.mcd" (issue #62).
  Future<File?> _cardByTitleWords(String memcardsDir, Game game, int port) async {
    final dir = Directory(memcardsDir);
    if (!await dir.exists()) return null;
    final stemTokens =
        _words(normalizeSaveMatchName(getRomStem(game))).where((w) => w.length >= 3).toList();
    if (stemTokens.isEmpty) return null;
    final suffix = '_$port.mcd';
    File? best;
    DateTime? bestModified;
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final base = p.basename(entity.path);
      final lower = base.toLowerCase();
      if (!lower.endsWith(suffix) || lower.startsWith('shared_card_')) continue;
      final cardTokens = _words(normalizeSaveMatchName(base.substring(0, base.length - suffix.length)));
      if (!stemTokens.every(cardTokens.contains)) continue;
      final modified = await entity.lastModified();
      if (best == null || modified.isAfter(bestModified!)) {
        best = entity;
        bestModified = modified;
      }
    }
    return best;
  }

  static List<String> _words(String text) => text
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]'), ' ')
      .split(' ')
      .where((w) => w.isNotEmpty)
      .toList();

  /// The port a card was made for: the `_N` of `<name>_N.mcd` or
  /// `shared_card_N.mcd`, the N of a legacy `McdN.mcd`, else port 1.
  static int _portOf(String fileName) {
    final base = p.basename(fileName).toLowerCase();
    final match =
        RegExp(r'_(\d+)\.mcd$').firstMatch(base) ?? RegExp(r'^mcd(\d+)\.mcd$').firstMatch(base);
    final port = match == null ? null : int.tryParse(match.group(1)!);
    return port != null && DuckstationMemcardConfig.ports.contains(port) ? port : 1;
  }

  static bool _isSharedCardName(String fileName) {
    final base = p.basename(fileName).toLowerCase();
    return base.startsWith('shared_card_') || RegExp(r'^mcd\d+\.mcd$').hasMatch(base);
  }

  @override
  Future<String?> saveSyncBlockedReason(Game game, String romPath) async {
    try {
      final config = (await _cardSetup(game, romPath)).config;
      if (config.portsOfType((t) => t.isPerGame).isNotEmpty) return null;
      if (config.portsOfType((t) => t == DuckstationCardType.shared).isNotEmpty) {
        return _sharedCardMessage;
      }
      return _noCardMessage;
    } catch (e) {
      debugPrint('[DuckStation] cannot tell whether saves can be synced: $e');
      return null;
    }
  }

  @override
  Future<String?> getSaveDir(Game game, String romPath) async =>
      (await _cardSetup(game, romPath, needSerial: false)).memcardsDir;

  @override
  Future<List<File>> getSaveFiles(Game game, String romPath,
      {DateTime? sessionStart, String syncMode = 'both'}) async {
    final setup = await _cardSetup(game, romPath);
    final config = setup.config;
    debugPrint('[DuckStation] memory cards: ${setup.memcardsDir}  serial=${setup.serial}  '
        'types=${DuckstationMemcardConfig.ports.map((port) => config.typeOf(port).iniValue).join(",")}  '
        'sessionStart=$sessionStart');

    bool changedThisSession(File file) =>
        sessionStart == null ||
        !file.statSync().modified.isBefore(sessionStart.subtract(const Duration(seconds: 2)));

    final result = <File>[];
    final perGamePorts = config.portsOfType((t) => t.isPerGame).toList();
    for (final port in perGamePorts) {
      final card = await _localCard(setup, game, romPath, port);
      if (card == null) {
        debugPrint('[DuckStation]   port $port (${config.typeOf(port).iniValue}): no card on disk');
      } else if (changedThisSession(card)) {
        debugPrint('[DuckStation]   port $port (${config.typeOf(port).iniValue}): ${card.path}');
        result.add(card);
      }
    }

    // Only shared cards: they can't be synced (see saveSyncBlockedReason),
    // but returning them keeps the local backups of them.
    if (perGamePorts.isEmpty) {
      for (final port in config.portsOfType((t) => t == DuckstationCardType.shared)) {
        final card =
            File(p.join(setup.memcardsDir, config.cardPaths[port] ?? 'shared_card_$port.mcd'));
        if (await card.exists() && changedThisSession(card)) result.add(card);
      }
    }

    // Save states are not part of the save: they sync separately through
    // StateSyncService (see [StateSyncCapable]).
    return result;
  }

  @override
  Future<bool> restoreSave(
      Game game, String destPath, Uint8List data, String filename) async {
    try {
      final cards = <(String, List<int>)>[];
      if (filename.toLowerCase().endsWith('.zip')) {
        for (final entry in ZipDecoder().decodeBytes(data)) {
          if (!entry.isFile) continue;
          // Only memory cards are restored from a saves bundle. Older
          // Freegosy versions bundled `savestates/` into it; states now sync
          // separately through StateSyncService, so never write them here.
          if (!entry.name.toLowerCase().endsWith('.mcd')) {
            debugPrint('[DuckStation]   skipping non-memcard entry: ${entry.name}');
            continue;
          }
          cards.add((p.basename(entry.name), entry.content as List<int>));
        }
      } else if (filename.toLowerCase().endsWith('.mcd')) {
        cards.add((p.basename(filename), data));
      } else {
        debugPrint('[DuckStation]   ignoring non-memcard save upload: $filename');
        return true;
      }
      // A game's own card wins over a shared one uploaded for the same port
      // by older versions: write the shared ones first.
      cards.sort((a, b) => (_isSharedCardName(a.$1) ? 0 : 1) - (_isSharedCardName(b.$1) ? 0 : 1));

      final setup = await _cardSetup(game, destPath);
      for (final (name, bytes) in cards) {
        final port = _portOf(name);
        final type = setup.config.typeOf(port);
        if (!type.isPerGame) {
          debugPrint('[DuckStation]   skipping $name: port $port is ${type.iniValue} here');
          continue;
        }
        final target = await _restoreTarget(setup, game, destPath, port);
        if (target == null) {
          debugPrint('[DuckStation]   skipping $name: no ${type.iniValue} card name for this game');
          continue;
        }
        debugPrint('[DuckStation]   restoring $name → ${target.path}');
        await target.parent.create(recursive: true);
        await backupSave(target.path);
        await target.writeAsBytes(bytes);
      }
      return true;
    } catch (e) {
      debugPrint('[DuckStation] restoreSave failed: $e');
      return false;
    }
  }

  /// Where [game]'s card for [port] goes on this PC: the exact name when
  /// known; by title, an existing card matched by name, else the ROM name
  /// without its tags (DuckStation's database title usually reads the same).
  Future<File?> _restoreTarget(_CardSetup setup, Game game, String romPath, int port) async {
    final type = setup.config.typeOf(port);
    final name = await _cardName(setup, type, game, romPath);
    if (name != null) return File(p.join(setup.memcardsDir, '${name}_$port.mcd'));
    if (type != DuckstationCardType.perGameTitle) return null;
    final existing = await _cardByTitleWords(setup.memcardsDir, game, port);
    if (existing != null) return existing;
    final guess = duckstationSafeFileName(normalizeSaveMatchName(getRomStem(game)));
    debugPrint('[DuckStation]   title unknown to the game database — naming the card "$guess"');
    return guess.isEmpty ? null : File(p.join(setup.memcardsDir, '${guess}_$port.mcd'));
  }
}

/// What [DuckstationSaveStrategy] needs to name a game's memory cards.
class _CardSetup {
  _CardSetup({required this.memcardsDir, required this.config, required this.serial});
  final String memcardsDir;
  final DuckstationMemcardConfig config;
  final String? serial;
}
