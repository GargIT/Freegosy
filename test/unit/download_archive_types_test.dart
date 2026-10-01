import 'package:flutter_test/flutter_test.dart';
import 'package:freegosy/core/downloader/download_service.dart';

void main() {
  test('.zip, .7z and .rar downloads are unpacked, whatever the case', () {
    expect(DownloadService.isExtractableArchive('/roms/windows/Game.zip'), isTrue);
    expect(DownloadService.isExtractableArchive('/roms/windows/Game.7z'), isTrue);
    expect(DownloadService.isExtractableArchive('/roms/windows/Game.rar'), isTrue);
    expect(DownloadService.isExtractableArchive('/roms/windows/GAME.RAR'), isTrue);
  });

  test('other files are left as downloaded', () {
    expect(DownloadService.isExtractableArchive('/roms/gba/Game.gba'), isFalse);
    expect(DownloadService.isExtractableArchive('/roms/psx/Game.chd'), isFalse);
    expect(DownloadService.isExtractableArchive('/roms/windows/Game.exe'), isFalse);
    expect(DownloadService.isExtractableArchive('/roms/windows/rar'), isFalse);
  });
}
