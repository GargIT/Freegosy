import 'dart:io';

/// Returns whether [path] exists, or null when that cannot be determined.
typedef PathProbe = Future<bool?> Function(String path);

/// Checks a file or directory without throwing.
///
/// On Windows, `exists()` throws a [FileSystemException] ("The device is not
/// ready") for a path on a drive letter that is present but has no media, such
/// as an empty SD card reader. That is reported as null (unknown) rather than
/// as an error so one unreachable path cannot abort a whole library scan.
Future<bool?> probePath(String path) async {
  try {
    return await File(path).exists() || await Directory(path).exists();
  } on FileSystemException {
    return null;
  }
}
