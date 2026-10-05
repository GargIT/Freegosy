import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:freegosy/core/downloader/download_service.dart';
import 'package:freegosy/core/extraction/extraction_service.dart';
import 'package:freegosy/core/platform/platform_info.dart';
import 'package:freegosy/core/storage/directory_service.dart';
import 'package:freegosy/ui/widgets/download_progress_indicator.dart';

class _SevenZipDirectoryService extends Fake implements DirectoryService {
  _SevenZipDirectoryService(this.path);
  final String path;

  @override
  Future<String?> resolveSevenZipPath() async => path;
}

void main() {
  group('extraction progress', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('extraction_progress_');
    });

    tearDown(() async {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    test('percentages printed by the extractor are reported as 0..1 fractions', () async {
      final sevenZip = p.join(tempDir.path, '7zz');
      await File(sevenZip).writeAsString(
        '#!/bin/sh\nprintf "  0%%\\r 25%%\\r 25%%\\r 70%%\\r100%%\\r"\nexit 0\n',
      );
      await Process.run('chmod', ['+x', sevenZip]);
      final archive = p.join(tempDir.path, 'game.rar');
      await File(archive).writeAsBytes([0]);
      final service = ExtractionService(_SevenZipDirectoryService(sevenZip), platform: PlatformInfo('macos'));
      final seen = <double>[];

      await service.extract(archive, tempDir.path, onProgress: seen.add);

      expect(seen, [0.0, 0.25, 0.7, 1.0]);
    }, skip: Platform.isWindows ? 'uses a shell script as the 7-Zip stand-in' : false);

    test('a file name containing a percentage, or an update split across chunks, does not move the bar', () async {
      final sevenZip = p.join(tempDir.path, '7zz');
      await File(sevenZip).writeAsString(
        '#!/bin/sh\n'
        'printf " 45%% 1 - Disc (50%%).iso\\r"\n'
        'sleep 0.3\n'
        'printf " 9"\n'
        'sleep 0.3\n'
        'printf "5%% 2 - 100%% Orange Juice.bin\\r"\n'
        'exit 0\n',
      );
      await Process.run('chmod', ['+x', sevenZip]);
      final archive = p.join(tempDir.path, 'game.rar');
      await File(archive).writeAsBytes([0]);
      final service = ExtractionService(_SevenZipDirectoryService(sevenZip), platform: PlatformInfo('macos'));
      final seen = <double>[];

      await service.extract(archive, tempDir.path, onProgress: seen.add);

      expect(seen, [0.45, 0.95]);
    }, skip: Platform.isWindows ? 'uses a shell script as the 7-Zip stand-in' : false);

    test('a failing extractor still throws with progress enabled', () async {
      final sevenZip = p.join(tempDir.path, '7zz');
      await File(sevenZip).writeAsString('#!/bin/sh\necho boom >&2\nexit 2\n');
      await Process.run('chmod', ['+x', sevenZip]);
      final archive = p.join(tempDir.path, 'game.7z');
      await File(archive).writeAsBytes([0]);
      final service = ExtractionService(_SevenZipDirectoryService(sevenZip), platform: PlatformInfo('macos'));

      await expectLater(
        () => service.extract(archive, tempDir.path, onProgress: (_) {}),
        throwsA(predicate((e) => e.toString().contains('boom'))),
      );
    }, skip: Platform.isWindows ? 'uses a shell script as the 7-Zip stand-in' : false);
  });

  group('DownloadProgress.isExtracting', () {
    test('true only for the extraction status', () {
      expect(DownloadProgress(id: '1', gameName: 'g', status: 'Extracting (rar)...').isExtracting, isTrue);
      expect(DownloadProgress(id: '1', gameName: 'g', status: 'Downloading...').isExtracting, isFalse);
      expect(DownloadProgress(id: '1', gameName: 'g', status: 'Done!').isExtracting, isFalse);
    });
  });

  group('DownloadProgressIndicator while extracting', () {
    Future<void> pump(WidgetTester tester, DownloadProgress progress) => tester.pumpWidget(
          MaterialApp(home: Scaffold(body: DownloadProgressIndicator(progress: progress))),
        );

    testWidgets('starts indeterminate with no percentage', (tester) async {
      await pump(tester, DownloadProgress(id: '1', gameName: 'g', status: 'Extracting (rar)...'));

      expect(tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator)).value, isNull);
      expect(find.text('Extracting (rar)...'), findsOneWidget);
    });

    testWidgets('shows the extraction percentage, not the finished download', (tester) async {
      await pump(tester, DownloadProgress(id: '1', gameName: 'g', percent: 0.4, status: 'Extracting (rar)...'));

      expect(tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator)).value, 0.4);
      expect(find.text('Extracting (rar)... — 40.0%'), findsOneWidget);
    });
  });
}
