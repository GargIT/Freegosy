import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// One save file: its name (no directory) and its bytes.
@immutable
class SaveBlob {
  const SaveBlob(this.name, this.bytes);

  final String name;
  final Uint8List bytes;

  /// The extension, lower-case, with its dot (`.srm`).
  String get extension => p.extension(name).toLowerCase();
}

/// One emulator family's way of storing one system's save. [N] is that
/// system's neutral form, which every format of the system decodes to and
/// encodes from. Pure: bytes and names in, bytes and names out.
abstract class SaveFormat<N> {
  const SaveFormat();

  /// Stable id for logs, e.g. `n64.mupen_srm`.
  String get id;

  /// The RomM `emulator` tags whose saves are in this format. Empty for a
  /// format that is only ever a source, recognised by its files.
  Set<String> get tags;

  /// Whether [files] look like this format (extension, size, header).
  bool recognises(List<SaveBlob> files);

  /// The save in neutral form. Throws [FormatException] when [files] aren't
  /// valid for this format.
  N decode(List<SaveBlob> files);

  /// [save] as this format's files, named for [stem], the ROM name the local
  /// emulator looks for. [existing] are the game's save files already on this
  /// machine, for a format that holds more than [save] carries to keep the
  /// rest of it.
  List<SaveBlob> encode(N save, {required String stem, List<SaveBlob> existing = const []});
}

/// The save formats of one system, which share the neutral form [N].
class SaveSystem<N> {
  const SaveSystem({required this.name, required this.slugs, required this.formats});

  final String name;

  /// Freegosy's platform slugs for the system (after canonicalPlatformSlug).
  final Set<String> slugs;
  final List<SaveFormat<N>> formats;

  /// [files] converted from the format they're in to the one [targetTag]'s
  /// emulator reads; null to leave them as they are (see convertSave).
  List<SaveBlob>? convert({
    required List<SaveBlob> files,
    String? sourceTag,
    required String targetTag,
    required String stem,
    List<SaveBlob> existing = const [],
  }) {
    final names = files.map((f) => f.name).join(', ');
    SaveFormat<N>? target;
    for (final format in formats) {
      if (format.tags.contains(targetTag)) {
        target = format;
        break;
      }
    }
    if (target == null) {
      _log('no $name save format for "$targetTag" — $names left as it is');
      return null;
    }

    SaveFormat<N>? source;
    if (sourceTag != null) {
      for (final format in formats) {
        if (format.tags.contains(sourceTag) && format.recognises(files)) {
          source = format;
          break;
        }
      }
    }
    if (source == null) {
      final candidates = [for (final format in formats) if (format.recognises(files)) format];
      if (candidates.length != 1) {
        _log(candidates.isEmpty
            ? 'no $name save format recognises $names — left as it is'
            : '$names could be ${candidates.map((f) => f.id).join(' or ')} — left as it is');
        return null;
      }
      source = candidates.single;
    }
    if (identical(source, target)) return null;

    try {
      final out = target.encode(source.decode(files), stem: stem, existing: existing);
      if (out.isEmpty) {
        _log('$names (${source.id}) holds nothing ${target.id} keeps — left as it is');
        return null;
      }
      _log('converted $names from ${source.id} to ${target.id}: ${out.map((f) => f.name).join(', ')}');
      return out;
    } on FormatException catch (e) {
      _log('$names is not valid ${source.id} (${e.message}) — left as it is');
      return null;
    }
  }

  static void _log(String message) => debugPrint('[SaveSync] [format] $message');
}
