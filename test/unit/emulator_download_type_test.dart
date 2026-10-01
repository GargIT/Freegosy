import 'package:flutter_test/flutter_test.dart';
import 'package:freegosy/core/emulator/emulator_download_service.dart';
import 'package:freegosy/core/emulator/emulator_registry_data.dart';
import 'package:freegosy/core/platform/platform_info.dart';

void main() {
  final dolphin = kEmulatorDefinitions.firstWhere((d) => d['id'] == 'dolphin');

  test('Dolphin is scraped from its site on Windows and macOS', () {
    expect(EmulatorDownloadService.typeFor(dolphin, PlatformInfo('windows'), fallback: 'direct'), 'dolphin');
    expect(EmulatorDownloadService.typeFor(dolphin, PlatformInfo('macos'), fallback: 'direct'), 'dolphin');
  });

  test('on Linux Dolphin downloads an AppImage from GitHub, not the unrunnable Flatpak bundle', () {
    expect(EmulatorDownloadService.typeFor(dolphin, PlatformInfo('linux'), fallback: 'direct'), 'github');
    expect(dolphin['github_repo'], 'pkgforge-dev/Dolphin-emu-AppImage');
    expect(dolphin['github_asset_required_linux'], containsAll(['x86_64', '.AppImage']));
    expect(dolphin['github_asset_excluded_linux'], contains('zsync'), reason: 'the .zsync file would make two matches');
  });

  test('an emulator without a linux_type keeps its type on Linux', () {
    final ppsspp = kEmulatorDefinitions.firstWhere((d) => d['id'] == 'ppsspp');
    expect(EmulatorDownloadService.typeFor(ppsspp, PlatformInfo('linux'), fallback: 'direct'), 'github');
  });

  test('the fallback is used when a definition has no type', () {
    expect(EmulatorDownloadService.typeFor(const {}, PlatformInfo('linux'), fallback: 'direct'), 'direct');
  });
}
