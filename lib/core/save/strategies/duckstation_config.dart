import 'dart:io' as io;
import 'dart:isolate';
import 'package:flutter/foundation.dart';

import '../../platform/platform_info.dart';

/// DuckStation's memory card types, as written in `settings.ini`
/// (`[MemoryCards] CardNType`).
enum DuckstationCardType {
  none('None'),
  shared('Shared'),
  perGameSerial('PerGame'),
  perGameTitle('PerGameTitle'),
  perGameFileTitle('PerGameFileTitle'),
  nonPersistent('NonPersistent');

  const DuckstationCardType(this.iniValue);
  final String iniValue;

  bool get isPerGame =>
      this == perGameSerial || this == perGameTitle || this == perGameFileTitle;

  static DuckstationCardType? fromIni(String? value) {
    if (value == null) return null;
    for (final type in values) {
      if (type.iniValue.toLowerCase() == value.trim().toLowerCase()) return type;
    }
    return null;
  }
}

/// The memory card settings DuckStation applies to one game: the global
/// `settings.ini`, overridden key by key by `gamesettings/<SERIAL>.ini`.
@immutable
class DuckstationMemcardConfig {
  const DuckstationMemcardConfig({
    required this.cardTypes,
    required this.cardPaths,
    required this.directory,
    required this.usePlaylistTitle,
  });

  /// Ports DuckStation has (1–8, two plus multitap).
  static const ports = [1, 2, 3, 4, 5, 6, 7, 8];

  /// Card type per port. DuckStation's defaults: port 1 a card per game named
  /// by title, the others no card.
  final Map<int, DuckstationCardType> cardTypes;

  /// `CardNPath` per port: the shared card's file (else `shared_card_N.mcd`).
  final Map<int, String> cardPaths;

  /// `Directory`: the memory card folder, relative to the data folder unless
  /// absolute. Null means DuckStation's default `memcards`.
  final String? directory;

  /// `UsePlaylistTitle`: one card for all discs of a multi-disc game.
  final bool usePlaylistTitle;

  DuckstationCardType typeOf(int port) =>
      cardTypes[port] ?? (port == 1 ? DuckstationCardType.perGameTitle : DuckstationCardType.none);

  Iterable<int> portsOfType(bool Function(DuckstationCardType type) test) =>
      ports.where((port) => test(typeOf(port)));

  /// Builds the config from the `[MemoryCards]` sections of [globalIni] and
  /// [gameIni] (either may be null).
  factory DuckstationMemcardConfig.fromIni(String? globalIni, [String? gameIni]) {
    final values = {
      ...parseIniSection(globalIni ?? '', 'MemoryCards'),
      ...parseIniSection(gameIni ?? '', 'MemoryCards'),
    };
    final types = <int, DuckstationCardType>{};
    final paths = <int, String>{};
    for (final port in ports) {
      final type = DuckstationCardType.fromIni(values['Card${port}Type']);
      if (type != null) types[port] = type;
      final path = values['Card${port}Path'];
      if (path != null && path.isNotEmpty) paths[port] = path;
    }
    final directory = values['Directory'];
    return DuckstationMemcardConfig(
      cardTypes: types,
      cardPaths: paths,
      directory: directory == null || directory.isEmpty ? null : directory,
      usePlaylistTitle: (values['UsePlaylistTitle'] ?? 'true').toLowerCase() != 'false',
    );
  }
}

/// The `key = value` pairs of [section] in INI [text]. Keys are
/// case-sensitive, as DuckStation writes them; later keys win.
Map<String, String> parseIniSection(String text, String section) {
  final result = <String, String>{};
  var inSection = false;
  for (final raw in text.split(RegExp(r'\r?\n'))) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith(';') || line.startsWith('#')) continue;
    if (line.startsWith('[') && line.endsWith(']')) {
      inSection = line.substring(1, line.length - 1).trim() == section;
      continue;
    }
    if (!inSection) continue;
    final eq = line.indexOf('=');
    if (eq <= 0) continue;
    result[line.substring(0, eq).trim()] = line.substring(eq + 1).trim();
  }
  return result;
}

/// [name] made safe as a file name the way DuckStation names memory cards on
/// [platform] (its `Path::SanitizeFileName`): control characters, `/` and
/// `*` become `_` everywhere; on Windows also `\ < > : " | ?` and a trailing
/// `.`; on macOS also `:`.
String duckstationSafeFileName(String name, PlatformInfo platform) {
  final forbidden = platform.isWindows
      ? RegExp(r'[\x00-\x1F/\\<>:"|?*]')
      : platform.isMacOS
          ? RegExp(r'[\x00-\x1F/*:]')
          : RegExp(r'[\x00-\x1F/*]');
  final safe = name.replaceAll(forbidden, '_');
  return platform.isWindows && safe.endsWith('.') ? '${safe.substring(0, safe.length - 1)}_' : safe;
}

/// The title DuckStation names a game's memory card by in "Separate Card Per
/// Game (Title)" mode, from its own `gamedb.yaml` (and `discsets.yaml` for
/// multi-disc games when [usePlaylistTitle]): the entry's `saveName`, else
/// its `name`. Read from the installed DuckStation, so it matches what that
/// DuckStation does. The files are parsed once and cached until they change.
class DuckstationGameDb {
  DuckstationGameDb._();

  static final _cache = <String, ({DateTime modified, Object value})>{};

  static String _gameDbPath(String resourcesDir) => '$resourcesDir${io.Platform.pathSeparator}gamedb.yaml';
  static String _discSetsPath(String resourcesDir) => '$resourcesDir${io.Platform.pathSeparator}discsets.yaml';

  /// The card title for [serial], or null when the database doesn't know it
  /// or can't be read.
  static Future<String?> saveTitle(String resourcesDir, String serial,
      {required bool usePlaylistTitle}) async {
    final key = serial.toUpperCase();
    if (usePlaylistTitle) {
      final set = await _load(_discSetsPath(resourcesDir), 'titles', parseDiscSets);
      final title = set?[key];
      if (title != null) return title;
    }
    final games = await _load(_gameDbPath(resourcesDir), 'titles', parseGameDb);
    return games?[key];
  }

  /// The disc set's card title when [serial] is a disc of a multi-disc game
  /// (per `discsets.yaml`), else null.
  static Future<String?> discSetTitle(String resourcesDir, String serial) async =>
      (await _load(_discSetsPath(resourcesDir), 'titles', parseDiscSets))?[serial.toUpperCase()];

  /// Every disc serial of the multi-disc game [serial] belongs to (per
  /// `discsets.yaml`), else just [serial]. A later disc often reads the
  /// saves an earlier one wrote under its own serial.
  static Future<List<String>> discSetSerials(String resourcesDir, String serial) async {
    final key = serial.toUpperCase();
    final members = await _load(_discSetsPath(resourcesDir), 'members', parseDiscSetMembers);
    return members?[key] ?? [key];
  }

  static Future<T?> _load<T extends Object>(String path, String kind, T Function(String text) parse) async {
    try {
      final file = io.File(path);
      if (!await file.exists()) return null;
      final modified = await file.lastModified();
      final cacheKey = '$path#$kind';
      final cached = _cache[cacheKey];
      if (cached != null && cached.modified == modified) return cached.value as T;
      final value = await Isolate.run(() => parse(io.File(path).readAsStringSync()));
      _cache[cacheKey] = (modified: modified, value: value);
      return value;
    } catch (e) {
      debugPrint('[DuckStation] cannot read $path: $e');
      return null;
    }
  }

  @visibleForTesting
  static void clearCache() => _cache.clear();

  /// `gamedb.yaml`: top-level `SERIAL:` keys, each with `name:` and an
  /// optional `saveName:` two spaces in.
  static Map<String, String> parseGameDb(String text) {
    final result = <String, String>{};
    String? serial;
    String? name;
    String? saveName;
    void flush() {
      final title = saveName ?? name;
      if (serial != null && title != null && title.isNotEmpty) result[serial] = title;
    }

    for (final line in text.split(RegExp(r'\r?\n'))) {
      final top = RegExp(r'^([A-Za-z0-9_-]+):\s*$').firstMatch(line);
      if (top != null) {
        flush();
        serial = top.group(1)!.toUpperCase();
        name = null;
        saveName = null;
        continue;
      }
      if (serial == null) continue;
      final field = RegExp(r'^  (name|saveName):\s*(.*)$').firstMatch(line);
      if (field == null) continue;
      final value = _yamlScalar(field.group(2)!);
      if (field.group(1) == 'name') {
        name = value;
      } else {
        saveName = value;
      }
    }
    flush();
    return result;
  }

  /// `discsets.yaml`: every serial maps to its set's `saveName`, else `name`.
  static Map<String, String> parseDiscSets(String text) {
    final result = <String, String>{};
    for (final set in _discSets(text)) {
      final title = set.title;
      if (title == null || title.isEmpty) continue;
      for (final serial in set.serials) {
        result.putIfAbsent(serial, () => title);
      }
    }
    return result;
  }

  /// `discsets.yaml`: every serial maps to all serials of its set.
  static Map<String, List<String>> parseDiscSetMembers(String text) {
    final result = <String, List<String>>{};
    for (final set in _discSets(text)) {
      for (final serial in set.serials) {
        result.putIfAbsent(serial, () => set.serials);
      }
    }
    return result;
  }

  /// The sets of `discsets.yaml`: each `- name:` with an optional
  /// `saveName:` and a `serials:` list.
  static List<({String? title, List<String> serials})> _discSets(String text) {
    final result = <({String? title, List<String> serials})>[];
    String? name;
    String? saveName;
    var serials = <String>[];
    var inSerials = false;
    void flush() {
      if (name != null || serials.isNotEmpty) {
        result.add((title: saveName ?? name, serials: List.unmodifiable(serials)));
      }
    }

    for (final line in text.split(RegExp(r'\r?\n'))) {
      final start = RegExp(r'^- name:\s*(.*)$').firstMatch(line);
      if (start != null) {
        flush();
        name = _yamlScalar(start.group(1)!);
        saveName = null;
        serials = <String>[];
        inSerials = false;
        continue;
      }
      final save = RegExp(r'^  saveName:\s*(.*)$').firstMatch(line);
      if (save != null) {
        saveName = _yamlScalar(save.group(1)!);
        inSerials = false;
        continue;
      }
      if (RegExp(r'^  serials:\s*$').hasMatch(line)) {
        inSerials = true;
        continue;
      }
      final item = RegExp(r'^    - ([A-Za-z0-9_-]+)\s*$').firstMatch(line);
      if (inSerials && item != null) {
        serials.add(item.group(1)!.toUpperCase());
        continue;
      }
      if (RegExp(r'^  \S').hasMatch(line)) inSerials = false;
    }
    flush();
    return result;
  }

  /// A plain, double-quoted or single-quoted YAML scalar on one line.
  static String _yamlScalar(String raw) {
    final value = raw.trim();
    if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
      return value
          .substring(1, value.length - 1)
          .replaceAllMapped(RegExp(r'\\(.)'), (m) => m.group(1)!);
    }
    if (value.length >= 2 && value.startsWith("'") && value.endsWith("'")) {
      return value.substring(1, value.length - 1).replaceAll("''", "'");
    }
    return value;
  }
}
