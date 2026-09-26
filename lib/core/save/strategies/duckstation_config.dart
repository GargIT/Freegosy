import 'dart:io' as io;
import 'dart:isolate';
import 'package:flutter/foundation.dart';

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

/// [name] made safe as a file name the way DuckStation does for memory
/// cards: characters Windows forbids in file names (and control characters)
/// become `_`.
String duckstationSafeFileName(String name) =>
    name.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_');

/// The title DuckStation names a game's memory card by in "Separate Card Per
/// Game (Title)" mode, from its own `gamedb.yaml` (and `discsets.yaml` for
/// multi-disc games when [usePlaylistTitle]): the entry's `saveName`, else
/// its `name`. Read from the installed DuckStation, so it matches what that
/// DuckStation does. The files are parsed once and cached until they change.
class DuckstationGameDb {
  DuckstationGameDb._();

  static final _cache = <String, ({DateTime modified, Map<String, String> titles})>{};

  /// The card title for [serial], or null when the database doesn't know it
  /// or can't be read.
  static Future<String?> saveTitle(String resourcesDir, String serial,
      {required bool usePlaylistTitle}) async {
    final key = serial.toUpperCase();
    if (usePlaylistTitle) {
      final set = await _titles('$resourcesDir${io.Platform.pathSeparator}discsets.yaml', parseDiscSets);
      final title = set?[key];
      if (title != null) return title;
    }
    final games = await _titles('$resourcesDir${io.Platform.pathSeparator}gamedb.yaml', parseGameDb);
    return games?[key];
  }

  static Future<Map<String, String>?> _titles(
      String path, Map<String, String> Function(String text) parse) async {
    try {
      final file = io.File(path);
      if (!await file.exists()) return null;
      final modified = await file.lastModified();
      final cached = _cache[path];
      if (cached != null && cached.modified == modified) return cached.titles;
      final titles = await Isolate.run(() => parse(io.File(path).readAsStringSync()));
      _cache[path] = (modified: modified, titles: titles);
      return titles;
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

  /// `discsets.yaml`: a list of sets, each `- name:` with an optional
  /// `saveName:` and a `serials:` list; every serial maps to the set's title.
  static Map<String, String> parseDiscSets(String text) {
    final result = <String, String>{};
    String? name;
    String? saveName;
    final serials = <String>[];
    var inSerials = false;
    void flush() {
      final title = saveName ?? name;
      if (title != null && title.isNotEmpty) {
        for (final serial in serials) {
          result.putIfAbsent(serial, () => title);
        }
      }
    }

    for (final line in text.split(RegExp(r'\r?\n'))) {
      final start = RegExp(r'^- name:\s*(.*)$').firstMatch(line);
      if (start != null) {
        flush();
        name = _yamlScalar(start.group(1)!);
        saveName = null;
        serials.clear();
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
