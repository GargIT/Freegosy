import '../../emulator/platform_slugs.dart';
import 'n64_save_formats.dart';
import 'ps1_card_formats.dart';
import 'save_format.dart';

export 'save_format.dart';

/// Every system whose saves Freegosy converts between emulators.
final List<SaveSystem<Object>> kSaveSystems = [ps1SaveSystem, n64SaveSystem];

/// [files], downloaded from RomM for a game on [platformSlug], in the format
/// and under the names the emulator tagged [targetTag] reads; null to restore
/// them exactly as they came: no system or target format for them, their
/// format can't be told, they already are in the target's format, or they
/// don't decode. [sourceTag] is the save's `emulator` on RomM. [stem] is the
/// ROM name the local emulator looks for. [existing] are the game's save
/// files already on this machine (see SaveFormat.encode).
List<SaveBlob>? convertSave({
  required String platformSlug,
  required List<SaveBlob> files,
  String? sourceTag,
  required String targetTag,
  required String stem,
  List<SaveBlob> existing = const [],
  List<SaveSystem<Object>>? systems,
}) =>
    saveSystemFor(platformSlug, systems: systems)
        ?.convert(files: files, sourceTag: sourceTag, targetTag: targetTag, stem: stem, existing: existing);

/// The save system of games on [platformSlug], if Freegosy converts them.
SaveSystem<Object>? saveSystemFor(String platformSlug, {List<SaveSystem<Object>>? systems}) {
  final slug = canonicalPlatformSlug(platformSlug.toLowerCase());
  for (final system in systems ?? kSaveSystems) {
    if (system.slugs.contains(slug)) return system;
  }
  return null;
}
