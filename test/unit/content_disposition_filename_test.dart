import 'package:flutter_test/flutter_test.dart';
import 'package:freegosy/core/downloader/download_service.dart';

/// Regression test for the "DOOM II" bug: a single-file-foldered game whose
/// RomM metadata (file_name / fs_name / files[]) never carries the real
/// extension (all of them come back as "doom 2", no ".vhd"). The download
/// still lands correctly at /api/roms/{id}/content/{name} and the server's
/// response tells the truth via Content-Disposition — but nothing read that
/// header, so the file was saved with no extension at all.
void main() {
  group('DownloadService.parseContentDispositionFileName', () {
    test('decodes the RFC 5987 filename* form (real RomM header)', () {
      const header =
          "attachment; filename*=UTF-8''doom%202.vhd; filename=\"doom%202.vhd\"";
      expect(DownloadService.parseContentDispositionFileName(header), 'doom 2.vhd');
    });

    test('falls back to quoted filename= when filename* is absent', () {
      const header = 'attachment; filename="Gamename.chd"';
      expect(DownloadService.parseContentDispositionFileName(header), 'Gamename.chd');
    });

    test('falls back to bare filename= when unquoted', () {
      const header = 'attachment; filename=Gamename.chd';
      expect(DownloadService.parseContentDispositionFileName(header), 'Gamename.chd');
    });

    test('returns null for a null header', () {
      expect(DownloadService.parseContentDispositionFileName(null), isNull);
    });

    test('returns null when there is no filename at all', () {
      expect(DownloadService.parseContentDispositionFileName('attachment'), isNull);
    });
  });
}
