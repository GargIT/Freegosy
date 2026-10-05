import 'dart:io' as io;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:freegosy/core/emulator/linux_strategies/native_linux_strategy.dart';
import '../../helpers/same_path.dart';

void main() {
  group('NativeLinuxStrategy - versioned AppImage names in emulators root', () {
    late NativeLinuxStrategy strategy;
    late io.Directory root;

    setUp(() async {
      strategy = NativeLinuxStrategy();
      root = await io.Directory.systemTemp.createTemp('freegosy_appimage_');
    });

    tearDown(() async {
      if (root.existsSync()) await root.delete(recursive: true);
    });

    Future<String> touch(String relative) async {
      final f = io.File(p.join(root.path, relative));
      await f.create(recursive: true);
      return f.path;
    }

    test('matches versioned name in the emulators root', () async {
      final expected = await touch('Cemu-2.6-x86_64.AppImage');
      expect(await strategy.findExecutable('cemu', 'Cemu.AppImage', root.path, null), expected);
    });

    test('matches versioned name in the per-emulator folder', () async {
      final expected = await touch('duckstation/DuckStation-x64.AppImage');
      expect(await strategy.findExecutable('duckstation', 'DuckStation.AppImage', root.path, null), samePath(expected));
    });

    test('finds an AppImage in the subfolder its release archive extracted to', () async {
      final expected = await touch('retroarch/RetroArch-Linux-x86_64/RetroArch-Linux-x86_64.AppImage');
      await io.Directory(p.join(root.path, 'retroarch', 'RetroArch-Linux-x86_64', 'RetroArch-Linux-x86_64.AppImage.home'))
          .create(recursive: true);
      expect(await strategy.findExecutable('retroarch', 'retroarch', root.path, null), samePath(expected));
    });

    test('a user-chosen folder is searched for the AppImage, and one subfolder down', () async {
      final nested = await touch('mine/RetroArch-Linux-x86_64/RetroArch-Linux-x86_64.AppImage');
      expect(await strategy.findAppImageInFolder(p.join(root.path, 'mine'), 'retroarch', 'retroarch'), samePath(nested));
      expect(await strategy.findAppImageInFolder(p.join(root.path, 'mine', 'RetroArch-Linux-x86_64'), 'retroarch', 'retroarch'), samePath(nested));
    });

    test("choosing an AppImage's .home data folder finds the AppImage beside it", () async {
      final appImage = await touch('retroarch/RetroArch-Linux-x86_64/RetroArch-Linux-x86_64.AppImage');
      final home = p.join(root.path, 'retroarch', 'RetroArch-Linux-x86_64', 'RetroArch-Linux-x86_64.AppImage.home');
      await io.Directory(p.join(home, '.config')).create(recursive: true);
      expect(await strategy.findAppImageInFolder('$home/', 'retroarch', 'retroarch'), samePath(appImage));
    });

    test('a user-chosen folder with no matching executable finds nothing', () async {
      await touch('other/readme.txt');
      expect(await strategy.findAppImageInFolder(p.join(root.path, 'other'), 'retroarch', 'retroarch'), isNull);
      expect(await strategy.findAppImageInFolder(p.join(root.path, 'missing'), 'retroarch', 'retroarch'), isNull);
    });

    test('matches registry name with suffix against bare id (pcsx2-qt)', () async {
      final expected = await touch('pcsx2-v2.3.0-linux-appimage-x64-Qt.AppImage');
      expect(await strategy.findExecutable('pcsx2', 'pcsx2-qt.AppImage', root.path, null), expected);
    });

    test('does not match an AppImage of a different emulator', () async {
      await touch('Cemu-2.6-x86_64.AppImage');
      await touch('scares-1.0.AppImage');
      final result = await strategy.findExecutable('ares', 'ares.AppImage', root.path, null);
      expect(result, isNot(contains('Cemu')));
      expect(result, isNot(contains('scares')));
    });
  });
}
