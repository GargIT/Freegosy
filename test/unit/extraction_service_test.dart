import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:freegosy/core/extraction/extraction_service.dart';
import 'package:freegosy/core/storage/directory_service.dart';
import 'package:freegosy/core/platform/platform_info.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('ExtractionService', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('extraction_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    ExtractionService createService(String platformOs) {
      SharedPreferences.setMockInitialValues({});
      // We can't easily create a DirectoryService with a fake platform here
      // since it does filesystem operations in initialize(). Use a minimal mock.
      final platform = PlatformInfo(platformOs);
      // Create a minimal ExtractionService — we only need the platform for dispatch
      return ExtractionService(_MinimalDirectoryService(), platform: platform);
    }

    /// Creates a ZIP file containing [files] map of {filename: content}.
    Future<String> createZip(Map<String, String> files) async {
      final zipPath = p.join(tempDir.path, 'test_archive.zip');
      final encoder = ZipFileEncoder();
      encoder.create(zipPath);
      for (final entry in files.entries) {
        final file = File(p.join(tempDir.path, entry.key));
        await file.writeAsString(entry.value);
        await encoder.addFile(file, entry.key);
      }
      encoder.close();
      return zipPath;
    }

    group('cross-platform ZIP extraction', () {
      test('.zip extracts on simulated macOS', () async {
        final zipPath = await createZip({'test.txt': 'Hello!'});
        final destDir = Directory(p.join(tempDir.path, 'ext_macos'));
        await destDir.create();
        final service = createService('macos');
        await service.extract(zipPath, destDir.path);
        expect(File(p.join(destDir.path, 'test.txt')).existsSync(), isTrue);
      });

      test('.zip extracts on simulated Linux', () async {
        final zipPath = await createZip({'test.txt': 'Hello!'});
        final destDir = Directory(p.join(tempDir.path, 'ext_linux'));
        await destDir.create();
        final service = createService('linux');
        await service.extract(zipPath, destDir.path);
        expect(File(p.join(destDir.path, 'test.txt')).existsSync(), isTrue);
      });

      test('.zip extracts on simulated Windows', () async {
        final zipPath = await createZip({'test.txt': 'Hello!'});
        final destDir = Directory(p.join(tempDir.path, 'ext_windows'));
        await destDir.create();
        final service = createService('windows');
        await service.extract(zipPath, destDir.path);
        expect(File(p.join(destDir.path, 'test.txt')).existsSync(), isTrue);
      });
    });

    group('platform guards', () {
      test('.dmg throws on simulated Linux', () async {
        final dmgPath = p.join(tempDir.path, 'test.dmg');
        await File(dmgPath).writeAsBytes([0x00, 0x01]);
        final destDir = Directory(p.join(tempDir.path, 'dmg_linux'));
        await destDir.create();
        final service = createService('linux');
        expect(
          () => service.extract(dmgPath, destDir.path),
          throwsA(isA<Exception>().having(
            (e) => e.toString(), 'message', contains('DMG extraction is only supported on macOS'),
          )),
        );
      });

      test('.dmg throws on simulated Windows', () async {
        final dmgPath = p.join(tempDir.path, 'test.dmg');
        await File(dmgPath).writeAsBytes([0x00, 0x01]);
        final destDir = Directory(p.join(tempDir.path, 'dmg_win'));
        await destDir.create();
        final service = createService('windows');
        expect(
          () => service.extract(dmgPath, destDir.path),
          throwsA(isA<Exception>().having(
            (e) => e.toString(), 'message', contains('DMG extraction is only supported on macOS'),
          )),
        );
      });

      test('.appimage throws on simulated macOS', () async {
        final appPath = p.join(tempDir.path, 'test.AppImage');
        await File(appPath).writeAsBytes([0x7F, 0x45, 0x4C, 0x46]);
        final destDir = Directory(p.join(tempDir.path, 'app_macos'));
        await destDir.create();
        final service = createService('macos');
        expect(
          () => service.extract(appPath, destDir.path),
          throwsA(isA<Exception>().having(
            (e) => e.toString(), 'message', contains('AppImage is only supported on Linux'),
          )),
        );
      });

      test('.appimage throws on simulated Windows', () async {
        final appPath = p.join(tempDir.path, 'test.AppImage');
        await File(appPath).writeAsBytes([0x7F, 0x45, 0x4C, 0x46]);
        final destDir = Directory(p.join(tempDir.path, 'app_win'));
        await destDir.create();
        final service = createService('windows');
        expect(
          () => service.extract(appPath, destDir.path),
          throwsA(isA<Exception>().having(
            (e) => e.toString(), 'message', contains('AppImage is only supported on Linux'),
          )),
        );
      });
    });

    group('RAR extraction', () {
      /// A real 100-byte RAR holding `Game/readme.txt` ("Hello from a RAR archive!\n").
      final rarBytes = base64.decode(
          'UmFyIRoHAM+QcwAADQAAAAAAAABnn3QAgC8AGgAAABoAAAADyDBlXgAAIVoUMA8ApIEAAEdhbWUvcmVhZG1lLnR4dEhlbGxvIGZyb20gYSBSQVIgYXJjaGl2ZSEKxD17AEAHAA==');

      Future<String> writeRar() async {
        final path = p.join(tempDir.path, 'game.rar');
        await File(path).writeAsBytes(rarBytes);
        return path;
      }

      /// A stand-in tool: a script that records its arguments in [log] and exits with [exitCode].
      Future<void> fakeTool(String path, String log, {int exitCode = 0}) async {
        await Directory(p.dirname(path)).create(recursive: true);
        await File(path).writeAsString('#!/bin/sh\necho "\$@" >> "$log"\nexit $exitCode\n');
        await Process.run('chmod', ['+x', path]);
      }

      final onPosix = !Platform.isWindows;
      final bundled7zz = File('thirdparty/7zz-linux');

      test('.rar extracts with the bundled 7-Zip on Linux', () async {
        final sevenZip = p.join(tempDir.path, '7zz-linux');
        await bundled7zz.copy(sevenZip);
        await Process.run('chmod', ['+x', sevenZip]);
        final archive = await writeRar();
        final destDir = Directory(p.join(tempDir.path, 'rar_out'))..createSync();
        final service = ExtractionService(_SevenZipDirectoryService(sevenZip), platform: PlatformInfo('linux'));

        await service.extract(archive, destDir.path);

        expect(File(p.join(destDir.path, 'Game', 'readme.txt')).readAsStringSync(), 'Hello from a RAR archive!\n');
      }, skip: !(Platform.isLinux && bundled7zz.existsSync()) ? 'needs Linux and thirdparty/7zz-linux' : false);

      test('.rar is routed to the bundled 7-Zip on macOS too', () async {
        final log = p.join(tempDir.path, 'args.txt');
        final sevenZip = p.join(tempDir.path, '7zz');
        await fakeTool(sevenZip, log);
        final archive = await writeRar();
        final service = ExtractionService(_SevenZipDirectoryService(sevenZip), platform: PlatformInfo('macos'));

        await service.extract(archive, tempDir.path);

        expect(File(log).readAsStringSync(), contains('x $archive -o${tempDir.path} -y'));
      }, skip: onPosix ? false : 'uses a shell script as the 7-Zip stand-in');

      group('on Windows (the bundled 7zr reads only 7z)', () {
        late String programFiles;
        late String log;

        setUp(() {
          programFiles = p.join(tempDir.path, 'Program Files');
          log = p.join(tempDir.path, 'args.txt');
        });

        ExtractionService windows() =>
            ExtractionService(_MinimalDirectoryService(), platform: PlatformInfo('windows', environment: {'ProgramFiles': programFiles}));

        test('an installed 7-Zip is used', () async {
          await fakeTool(p.join(programFiles, '7-Zip', '7z.exe'), log);
          final archive = await writeRar();

          await windows().extract(archive, tempDir.path);

          expect(File(log).readAsStringSync(), contains('x $archive -o${tempDir.path} -y'));
        }, skip: onPosix ? false : 'uses a shell script as the 7-Zip stand-in');

        test('WinRAR\'s UnRAR is used when there is no 7-Zip', () async {
          await fakeTool(p.join(programFiles, 'WinRAR', 'UnRAR.exe'), log);
          final archive = await writeRar();

          await windows().extract(archive, tempDir.path);

          expect(File(log).readAsStringSync(), contains('x -y -o+ $archive ${tempDir.path}${p.separator}'));
        }, skip: onPosix ? false : 'uses a shell script as the UnRAR stand-in');

        test('UnRAR is tried when 7-Zip fails', () async {
          await fakeTool(p.join(programFiles, '7-Zip', '7z.exe'), log, exitCode: 2);
          await fakeTool(p.join(programFiles, 'WinRAR', 'UnRAR.exe'), log);
          final archive = await writeRar();

          await windows().extract(archive, tempDir.path);

          final calls = File(log).readAsLinesSync();
          expect(calls.length, 2);
          expect(calls.first, startsWith('x $archive'));
          expect(calls.last, startsWith('x -y -o+'));
        }, skip: onPosix ? false : 'uses shell scripts as stand-ins');

        test('with nothing able to read it, the error says what to install and the file is not touched', () async {
          final archive = await writeRar();
          final destDir = Directory(p.join(tempDir.path, 'none'))..createSync();

          await expectLater(
            windows().extract(archive, destDir.path),
            throwsA(isA<Exception>().having((e) => e.toString(), 'message', contains('Install 7-Zip'))),
          );
          expect(File(archive).existsSync(), isTrue);
        }, skip: onPosix ? false : 'depends on the machine\'s tar');
      });
    });

    group('magic byte detection', () {
      test('unknown extension with ZIP magic extracts on all platforms', () async {
        for (final os in ['macos', 'linux', 'windows']) {
          final zipPath = await createZip({'magic.txt': 'content'});
          final renamedPath = p.join(tempDir.path, 'archive_$os.bin');
          await File(zipPath).copy(renamedPath);
          final destDir = Directory(p.join(tempDir.path, 'magic_$os'));
          await destDir.create();
          final service = createService(os);
          await service.extract(renamedPath, destDir.path);
          expect(File(p.join(destDir.path, 'magic.txt')).existsSync(), isTrue,
              reason: 'Failed on $os');
        }
      });

      test('unknown extension without ZIP magic throws on all platforms', () async {
        for (final os in ['macos', 'linux', 'windows']) {
          final fakePath = p.join(tempDir.path, 'fake_$os.bin');
          await File(fakePath).writeAsBytes([0x00, 0x01, 0x02, 0x03]);
          final destDir = Directory(p.join(tempDir.path, 'fake_$os'));
          await destDir.create();
          final service = createService(os);
          expect(
            () => service.extract(fakePath, destDir.path),
            throwsA(isA<Exception>()),
            reason: 'Should throw on $os',
          );
        }
      });
    });
  });
}

/// Minimal DirectoryService stub for ExtractionService tests.
/// Only `resolveSevenZipPath` is called by the 7z handler.
class _MinimalDirectoryService extends Fake implements DirectoryService {
  @override
  Future<String?> resolveSevenZipPath() async => null;
}

/// A DirectoryService whose 7-Zip is the file at [path].
class _SevenZipDirectoryService extends Fake implements DirectoryService {
  _SevenZipDirectoryService(this.path);
  final String path;

  @override
  Future<String?> resolveSevenZipPath() async => path;
}
