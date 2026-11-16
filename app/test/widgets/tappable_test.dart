import 'package:flutter/material.dart' hide StepState;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yantra_app/core/theme/app_theme.dart';
import 'package:yantra_app/core/theme/portal_tokens.dart';
import 'package:yantra_app/core/widgets/cards.dart';
import 'package:yantra_app/core/widgets/side_sheet.dart';
import 'package:yantra_app/core/widgets/steps.dart';
import 'package:yantra_app/core/widgets/tables.dart';
import 'package:yantra_app/core/widgets/tappable.dart';

Widget host(Widget child, {double textScale = 1}) => MaterialApp(
  theme: AppTheme.light,
  home: MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
    child: Scaffold(body: Center(child: child)),
  ),
);

BoxDecoration? ringOf(WidgetTester tester) {
  final box = tester.widget<DecoratedBox>(find.byKey(const Key('tappable-ring')));
  return box.decoration is BoxDecoration ? box.decoration as BoxDecoration : null;
}

void main() {
  testWidgets('keyboard focus paints a 2px ring in the ring colour; Enter and Space activate', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      host(
        PortalTappable(
          onTap: () => taps++,
          child: const SizedBox(width: 120, height: 40, child: Text('Go')),
        ),
      ),
    );
    final border = ringOf(tester)?.border as Border?;
    expect(border?.top.width ?? 0, 0, reason: 'no ring until focused');
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    final ring = ringOf(tester)!.border! as Border;
    expect(ring.top.color, PortalTokens.light.ring);
    expect(ring.top.width, 2);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(taps, 2);
  });

  testWidgets('a tappable is a button for assistive tech and shows the click cursor', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(host(PortalTappable(onTap: () {}, semanticsLabel: 'Open batch', child: const Text('Batch'))));
    expect(
      tester.getSemantics(find.byType(PortalTappable)),
      matchesSemantics(isButton: true, hasTapAction: true, isFocusable: true, hasFocusAction: true, label: 'Open batch\nBatch'),
    );
    final region = tester.widgetList<MouseRegion>(find.descendant(of: find.byType(PortalTappable), matching: find.byType(MouseRegion)));
    expect(region.any((r) => r.cursor == SystemMouseCursors.click), isTrue);
    handle.dispose();
  });

  testWidgets('a KPI tile reads as one sentence', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      host(
        const SizedBox(
          width: 240,
          child: KpiTile(label: 'Open units', value: '42', note: 'across 3 batches'),
        ),
      ),
    );
    expect(find.bySemanticsLabel('Open units, 42. across 3 batches'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('table headers are headers; a tappable row is a button; rows grow with large text', (tester) async {
    final handle = tester.ensureSemantics();
    var opened = 0;
    final table = SizedBox(
      width: 700,
      child: PortalTable(
        columns: const [PortalColumn('Name'), PortalColumn('Units', numeric: true)],
        rows: [
          PortalRow(
            const [Text('Hindi speech transcription with a long name that wraps'), Text('8')],
            onTap: () => opened++,
            key: const Key('row-1'),
          ),
        ],
      ),
    );
    await tester.pumpWidget(host(table));
    expect(tester.getSemantics(find.text('Name')), matchesSemantics(isHeader: true, label: 'Name'));
    await tester.tap(find.byKey(const Key('row-1')));
    expect(opened, 1);
    expect(tester.getSize(find.byKey(const Key('row-1'))).height, closeTo(44, 1));
    await tester.pumpWidget(host(table, textScale: 2));
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byKey(const Key('row-1'))).height, greaterThan(44));
    handle.dispose();
  });

  testWidgets('a step says its place and state; a progress bar carries its value', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      host(
        const SizedBox(
          width: 400,
          child: StepList(
            steps: [
              StepTile(title: 'Profile', state: StepState.done),
              StepTile(title: 'Documents', state: StepState.active),
            ],
          ),
        ),
      ),
    );
    expect(find.bySemanticsLabel(RegExp(r'^Step 1 of 2, done')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^Step 2 of 2, in progress')), findsOneWidget);
    expect(tester.getSemantics(find.byType(ProgressBar)), matchesSemantics(value: '50%'));
    handle.dispose();
  });

  testWidgets('the side sheet opens without a slide when motion is reduced', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: MediaQuery(
          data: const MediaQueryData(size: Size(1280, 800), disableAnimations: true),
          child: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showSideSheet<void>(context, title: 'Sheet', builder: (_) => const Text('sheet body')),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.text('sheet body'), findsOneWidget);
    expect(tester.getTopLeft(find.text('sheet body')).dx, lessThan(1280 - 400), reason: 'already in place one frame later');
  });
}
