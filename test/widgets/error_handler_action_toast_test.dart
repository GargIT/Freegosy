import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:freegosy/core/error/error_handler.dart';

void main() {
  const title = 'Save State Conflict';
  const message = '2 save state(s) changed on both this PC and RomM.';

  Future<List<int>> open(WidgetTester tester, {bool persistent = true}) async {
    final calls = <int>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => ErrorHandler.showWithAction(
              context,
              title,
              message: message,
              actionLabel: 'Resolve',
              onAction: () => calls.add(calls.length),
              persistent: persistent,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pump();
    // Let the entrance animation finish so the action and close icon hit-test.
    await tester.pump(const Duration(milliseconds: 750));
    return calls;
  }

  testWidgets('shows title, message, action label and a close icon',
      (tester) async {
    await open(tester);

    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.text(title), findsOneWidget);
    expect(find.text(message), findsOneWidget);
    expect(find.text('Resolve'), findsOneWidget);
    expect(find.byIcon(Icons.close), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber_outlined), findsOneWidget);
  });

  testWidgets('stays visible long after any auto-dismiss duration',
      (tester) async {
    await open(tester);

    await tester.pump(const Duration(seconds: 60));
    // Settle so an auto-dismiss (timer fired + exit animation) would have
    // completed; a persistent snackbar has nothing to settle.
    await tester.pumpAndSettle();

    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.text(title), findsOneWidget);
  });

  testWidgets('tapping the action calls back once and dismisses the snackbar',
      (tester) async {
    final calls = await open(tester);

    await tester.tap(find.text('Resolve'));
    await tester.pumpAndSettle();

    expect(calls, hasLength(1));
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('tapping the close icon dismisses without calling the action',
      (tester) async {
    final calls = await open(tester);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    expect(calls, isEmpty);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('a non-persistent call auto-dismisses after its duration',
      (tester) async {
    await open(tester, persistent: false);
    expect(find.byType(SnackBar), findsOneWidget);

    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();

    expect(find.byType(SnackBar), findsNothing);
  });
}
