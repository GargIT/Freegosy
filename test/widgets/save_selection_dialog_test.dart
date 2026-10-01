import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:freegosy/ui/screens/library_dialog_service.dart';

/// Select Cloud Save lists RomM's saves for a game. Like RomM's own save
/// lists, each row shows the emulator tag the save was uploaded with and its
/// size.
void main() {
  Future<void> open(WidgetTester tester, List<Map<String, dynamic>> saves) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => LibraryDialogService.showSaveSelectionDialog(context, saves),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('each save shows its emulator tag and size', (tester) async {
    await open(tester, [
      {'file_name': 'Mario Kart 64 (U) [!].srm', 'emulator': 'mupen64plus_next', 'file_size_bytes': 296960},
      {'file_name': 'Mario Kart 64 (U) [!].eeprom', 'emulator': 'ares', 'file_size_bytes': 512},
      {'file_name': 'Mario Kart 64.zip', 'emulator': 'freegosy', 'file_size_bytes': 3 * 1024 * 1024 + 300 * 1024},
    ]);

    expect(find.text('mupen64plus_next'), findsOneWidget);
    expect(find.text('ares'), findsOneWidget);
    expect(find.text('freegosy'), findsOneWidget);
    expect(find.text('290.0 KB'), findsOneWidget);
    expect(find.text('512 B'), findsOneWidget);
    expect(find.text('3.3 MB'), findsOneWidget);
  });

  testWidgets('a save without a tag or size shows neither', (tester) async {
    await open(tester, [
      {'file_name': 'old.srm'},
      {'file_name': 'blank.srm', 'emulator': '', 'file_size_bytes': null},
    ]);

    expect(find.text('old.srm'), findsOneWidget);
    expect(find.textContaining(RegExp(r'^\d+(\.\d)? (B|KB|MB|GB)$')), findsNothing);
    expect(find.byKey(const ValueKey('save-emulator-tag')), findsNothing);
  });
}
