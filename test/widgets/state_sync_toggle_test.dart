import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:freegosy/ui/widgets/state_sync_toggle.dart';

void main() {
  Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

  testWidgets('unsupported emulators show a disabled switch and "Not supported yet"', (tester) async {
    var changes = 0;
    await tester.pumpWidget(host(StateSyncToggle(
      supported: false,
      enabled: true, // a stored "on" must not show as on
      onChanged: (_) => changes++,
    )));

    final toggle = tester.widget<Switch>(find.byType(Switch));
    expect(toggle.onChanged, isNull);
    expect(toggle.value, isFalse);
    expect(find.text('Not supported yet'), findsOneWidget);
    expect(changes, 0);
  });

  testWidgets('supported emulators show an enabled switch that reports changes', (tester) async {
    bool? changed;
    await tester.pumpWidget(host(StateSyncToggle(
      supported: true,
      enabled: false,
      onChanged: (value) => changed = value,
    )));

    expect(find.text('Sync save states'), findsOneWidget);
    expect(find.text('Not supported yet'), findsNothing);

    await tester.tap(find.byType(Switch));
    await tester.pump();

    expect(changed, isTrue);
  });

  testWidgets('a custom label replaces the default one', (tester) async {
    await tester.pumpWidget(host(StateSyncToggle(
      label: 'Auto-load resume state on launch',
      supported: true,
      enabled: true,
      onChanged: (_) {},
    )));

    expect(find.text('Auto-load resume state on launch'), findsOneWidget);
    expect(find.text('Sync save states'), findsNothing);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
  });

  testWidgets('a custom label is still disabled and marked "Not supported yet" when unsupported',
      (tester) async {
    await tester.pumpWidget(host(StateSyncToggle(
      label: 'Auto-load resume state on launch',
      supported: false,
      enabled: true,
      onChanged: (_) {},
    )));

    final toggle = tester.widget<Switch>(find.byType(Switch));
    expect(toggle.onChanged, isNull);
    expect(toggle.value, isFalse);
    expect(find.text('Auto-load resume state on launch'), findsOneWidget);
    expect(find.text('Not supported yet'), findsOneWidget);
  });
}
