import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:freegosy/core/romm/romm_models.dart';
import 'package:freegosy/core/save/state_sync_service.dart';
import 'package:freegosy/ui/widgets/save_conflict_dialog.dart';

void main() {
  final conflict = StateConflict(
    game: Game(id: '42', name: 'Ico', platformSlug: 'ps2', fileSize: 0),
    romPath: '/roms/Ico.iso',
    emulatorId: 'pcsx2',
    fileName: 'SCUS-97113 (A1B2C3D4).01.p2s',
    localPath: '/pcsx2/sstates/SCUS-97113 (A1B2C3D4).01.p2s',
    cloudStateId: 7,
    cloudUpdatedAt: '2026-01-01T00:00:00Z',
    localTime: DateTime(2026, 1, 2),
    cloudTime: DateTime(2026, 1, 1),
  );

  Future<String?> open(WidgetTester tester, String choiceLabel) async {
    String? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () async {
            result = await showDialog<String>(
              context: context,
              builder: (_) => SaveConflictDialog.forState(conflict: conflict),
            );
          },
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.textContaining('save state "SCUS-97113 (A1B2C3D4).01.p2s"'), findsOneWidget);
    expect(find.textContaining('Ico'), findsWidgets);
    await tester.tap(find.text(choiceLabel));
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('choosing the cloud version returns "cloud"', (tester) async {
    expect(await open(tester, 'Use Cloud Version'), 'cloud');
  });

  testWidgets('choosing the local version returns "local"', (tester) async {
    expect(await open(tester, 'Use Local Version'), 'local');
  });
}
