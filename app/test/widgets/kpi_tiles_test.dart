import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yantra_app/core/theme/app_theme.dart';
import 'package:yantra_app/core/widgets/cards.dart';

void main() {
  testWidgets('a tappable KPI tile is a button a screen reader can activate', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: Column(
            children: [
              KpiTile(label: 'Open claims', value: '4', onTap: () => taps++),
              const KpiTile(label: 'Paid', value: '₹10'),
            ],
          ),
        ),
      ),
    );
    final handle = tester.ensureSemantics();
    await tester.pump();
    final open = tester.getSemantics(find.bySemanticsLabel('Open claims, 4'));
    expect(open.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    tester.semantics.tap(find.semantics.byLabel('Open claims, 4'));
    await tester.pump();
    expect(taps, 1);
    final paid = tester.getSemantics(find.bySemanticsLabel('Paid, ₹10'));
    expect(paid.getSemanticsData().hasAction(SemanticsAction.tap), isFalse);
    handle.dispose();
  });
}
