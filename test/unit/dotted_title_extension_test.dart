import 'package:flutter_test/flutter_test.dart';
import 'package:freegosy/core/downloader/download_service.dart';

/// A dot inside a game title ("Vol. 1") used to be read as the file extension,
/// which skipped the extension fix-up and left the download extensionless.
void main() {
  group('DownloadService.hasRealExtension', () {
    test('dotted title without a real extension is not an extension', () {
      expect(
          DownloadService.hasRealExtension(
              '/roms/ps2/Test Quest Vol. 1 - The Beginning/Test Quest Vol. 1 - The Beginning'),
          isFalse);
    });

    test('plain title without a dot has no extension', () {
      expect(DownloadService.hasRealExtension('/roms/ps2/Sample Saga II/Sample Saga II'), isFalse);
    });

    test('real extensions are recognised, also after a dotted title', () {
      expect(DownloadService.hasRealExtension('/roms/ps2/Sample Saga II/Sample Saga II.chd'), isTrue);
      expect(DownloadService.hasRealExtension('/roms/ps2/Test Quest Vol. 1/Test Quest Vol. 1.iso'), isTrue);
      expect(DownloadService.hasRealExtension('/roms/ps2/Game/Game.7z'), isTrue);
    });
  });
}
