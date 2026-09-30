import '../../emulator/platform_slugs.dart';
import 'save_format.dart';

export 'save_format.dart';

/// Every system whose saves Freegosy converts between emulators.
final List<SaveSystem<Object>> kSaveSystems = [];

/// [files], downloaded from RomM for a game on [platformSlug], in the format
/// and under the names the emulator tagged [targetTag] reads; null to restore
/// them exactly as they came: no system or target format for them, their
/// format can't be told, they already are in the target's format, or they
/// don't decode. [sourceTag] is the save's `emulator` on RomM. [stem] is the
/// ROM name the local emulator looks for.
List<SaveBlob>? convertSave({
  required String platformSlug,
  required List<SaveBlob> files,
  String? sourceTag,
  required String targetTag,
  required String stem,
  List<SaveSystem<Object>>? systems,
}) {
  final slug = canonicalPlatformSlug(platformSlug.toLowerCase());
  for (final system in systems ?? kSaveSystems) {
    if (system.slugs.contains(slug)) {
      return system.convert(files: files, sourceTag: sourceTag, targetTag: targetTag, stem: stem);
    }
  }
  return null;
}
