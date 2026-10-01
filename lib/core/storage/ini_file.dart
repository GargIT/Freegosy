import 'dart:io' as io;

/// A small editor for `Key = Value` INI files (PCSX2, DuckStation, PPSSPP,
/// Dolphin...) that changes only the lines asked for. Everything else —
/// comments, order, unknown sections, the file's line endings — is written
/// back as it was, so an emulator's own settings are never reformatted.
class IniFile {
  IniFile(String text)
      : _eol = text.contains('\r\n') ? '\r\n' : '\n',
        _lines = _split(text);

  final String _eol;
  final List<String> _lines;

  static final _sectionPattern = RegExp(r'^\s*\[([^\]]*)\]\s*$');
  static final _keyPattern = RegExp(r'^\s*([^=;#\[\s][^=]*?)\s*=\s?(.*)$');

  static List<String> _split(String text) {
    if (text.isEmpty) return [];
    final lines = text.split(RegExp(r'\r?\n'));
    if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
    return lines;
  }

  /// First line index of [section]'s body and the index just past its last
  /// line, or null when the section doesn't exist.
  ({int start, int end})? _range(String section) {
    var start = -1;
    for (var i = 0; i < _lines.length; i++) {
      final match = _sectionPattern.firstMatch(_lines[i]);
      if (match == null) continue;
      if (start >= 0) return (start: start, end: i);
      if (match.group(1) == section) start = i + 1;
    }
    return start >= 0 ? (start: start, end: _lines.length) : null;
  }

  int? _keyLine(String section, String key) {
    final range = _range(section);
    if (range == null) return null;
    for (var i = range.start; i < range.end; i++) {
      final match = _keyPattern.firstMatch(_lines[i]);
      if (match != null && match.group(1) == key) return i;
    }
    return null;
  }

  /// The value of [key] in [section], or null when it isn't there.
  String? get(String section, String key) {
    final line = _keyLine(section, key);
    return line == null ? null : _keyPattern.firstMatch(_lines[line])!.group(2)!.trim();
  }

  /// Sets [key] in [section], creating either when missing. Returns whether
  /// anything changed (false when the value was already [value]).
  bool set(String section, String key, String value) {
    final line = _keyLine(section, key);
    if (line != null) {
      if (get(section, key) == value) return false;
      _lines[line] = '$key = $value';
      return true;
    }
    final range = _range(section);
    if (range == null) {
      if (_lines.isNotEmpty && _lines.last.trim().isNotEmpty) _lines.add('');
      _lines
        ..add('[$section]')
        ..add('$key = $value');
      return true;
    }
    // After the section's last non-blank line, so blank separators stay put.
    var at = range.end;
    while (at > range.start && _lines[at - 1].trim().isEmpty) {
      at--;
    }
    _lines.insert(at, '$key = $value');
    return true;
  }

  /// Removes [key] from [section]. Returns whether it was there.
  bool remove(String section, String key) {
    final line = _keyLine(section, key);
    if (line == null) return false;
    _lines.removeAt(line);
    return true;
  }

  /// The file's text, ending in a line break unless the file is empty.
  String toText() => _lines.isEmpty ? '' : '${_lines.join(_eol)}$_eol';
}

/// Reads [file] (an empty ini when it is missing and [create]), runs [edit] on
/// it and writes it back only if [edit] reports a change; returns whether it
/// did. [backup] copies an existing file to `<name>.freegosy.bak` first, once.
/// A [private] file is made readable by its owner alone (`chmod 600`, not on
/// [windows]) before anything secret goes into it.
Future<bool> updateIniFile(
  io.File file,
  bool Function(IniFile ini) edit, {
  bool backup = false,
  bool create = false,
  bool private = false,
  bool windows = false,
}) async {
  final exists = await file.exists();
  if (!exists && !create) return false;
  final ini = IniFile(exists ? await file.readAsString() : '');
  if (!edit(ini)) return false;
  if (backup && exists) {
    final copy = io.File('${file.path}.freegosy.bak');
    if (!await copy.exists()) await file.copy(copy.path);
  }
  if (!exists) {
    await file.parent.create(recursive: true);
    await file.writeAsString('', flush: true);
  }
  if (private && !windows) await io.Process.run('chmod', ['600', file.path]);
  await file.writeAsString(ini.toText(), flush: true);
  return true;
}
