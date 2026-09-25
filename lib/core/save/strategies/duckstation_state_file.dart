import 'dart:io' as io;
import 'package:flutter/foundation.dart';

/// Reads what a DuckStation `.sav` state records about itself.
///
/// The file starts with a plain header: the magic `DUCC`, a u32 (little
/// endian) state format version, then title, serial, disc path and the
/// offsets of the (compressed) screenshot and state data. It does not record
/// the DuckStation build that wrote it, so the format version is all there is
/// to show.
class DuckstationStateFile {
  DuckstationStateFile._();

  static const _magic = [0x44, 0x55, 0x43, 0x43]; // "DUCC"

  /// Whether [head] starts with DuckStation's state magic.
  static bool hasMagic(Uint8List head) {
    if (head.length < _magic.length) return false;
    for (var i = 0; i < _magic.length; i++) {
      if (head[i] != _magic[i]) return false;
    }
    return true;
  }

  /// The state format version from [head], or null if [head] isn't a
  /// DuckStation state header.
  static int? parseFormatVersion(Uint8List head) {
    if (head.length < 8 || !hasMagic(head)) return null;
    final version = ByteData.sublistView(head).getUint32(4, Endian.little);
    return version == 0 ? null : version;
  }

  /// [parseFormatVersion] on the start of [file]; null on any failure.
  static Future<int?> readFormatVersion(io.File file) async {
    io.RandomAccessFile? raf;
    try {
      raf = await file.open();
      return parseFormatVersion(await raf.read(8));
    } catch (e) {
      debugPrint('[DuckStation] cannot read state format of ${file.path}: $e');
      return null;
    } finally {
      await raf?.close();
    }
  }
}
