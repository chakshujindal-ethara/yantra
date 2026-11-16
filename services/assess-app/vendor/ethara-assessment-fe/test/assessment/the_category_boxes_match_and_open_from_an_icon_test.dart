// The Strengths / Needs coaching pair reads as one row of the same control.
//
// An empty side used to render two lines shorter than a filled one and sit
// lower in the row, and the only sign a box opened anything was a trailing
// "tap for the full list" caption that read as text, not as a control. Now
// both boxes share one height, a filled box carries an expand icon whose
// tooltip says "Show all N", and a screen reader hears what the tap does.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/domain/category_scores.dart';
import 'package:ethara_assessment/assessment/widgets/category_card.dart';

/// Three categories at the pass mark and none below it.
const List<CategoryScore> _allStrong = <CategoryScore>[
  CategoryScore(
    tag: 'skill:load-handling',
    earned: 90,
    possible: 100,
    answers: 3,
  ),
  CategoryScore(
    tag: 'skill:pre-shift-inspection',
    earned: 85,
    possible: 100,
    answers: 2,
  ),
  CategoryScore(
    tag: 'skill:pedestrian-awareness',
    earned: 80,
    possible: 100,
    answers: 2,
  ),
];

Future<void> _show(WidgetTester t) async {
  t.view.physicalSize = const Size(1200, 1600);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: const Scaffold(
        body: CategoryCard(
          scores: _allStrong,
          threshold: 75,
          audience: CategoryAudience.operator,
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
}

/// The bordered card that holds the box titled [eyebrow].
Finder _box(String eyebrow) => find
    .ancestor(
      of: find.text(eyebrow),
      matching: find.byWidgetPredicate(
        (Widget w) => w is Container && w.decoration is BoxDecoration,
      ),
    )
    .first;

void main() {
  testWidgets('a filled box and an empty box are the same height', (
    WidgetTester t,
  ) async {
    await _show(t);
    expect(find.text('Nothing below the pass mark'), findsOneWidget);
    expect(
      t.getSize(_box('NEEDS COACHING')).height,
      t.getSize(_box('STRENGTHS')).height,
    );
  });

  testWidgets('a filled box opens from an expand icon, not a caption', (
    WidgetTester t,
  ) async {
    await _show(t);
    expect(find.textContaining('tap for the full list'), findsNothing);
    final Finder icon = find.byIcon(Icons.open_in_full_rounded);
    // Only the filled side: an empty one opens nothing.
    expect(icon, findsOneWidget);
    expect(
      find.descendant(of: _box('STRENGTHS'), matching: icon),
      findsOneWidget,
    );
    expect(
      find.ancestor(of: icon, matching: find.byType(Tooltip)),
      findsOneWidget,
    );
    expect(
      t
          .widget<Tooltip>(
            find.ancestor(of: icon, matching: find.byType(Tooltip)),
          )
          .message,
      'Show all 3',
    );
  });

  testWidgets('a screen reader hears what the tap does', (
    WidgetTester t,
  ) async {
    final SemanticsHandle sem = t.ensureSemantics();
    await _show(t);
    // The box's own text follows on the same node, so the label LEADS with
    // the announcement rather than being all of it.
    final Finder node = find.bySemanticsLabel(
      RegExp(r'^Strengths: show all 3 categories'),
    );
    expect(node, findsOneWidget);
    final SemanticsData data = t.getSemantics(node).getSemanticsData();
    expect(data.flagsCollection.isButton, isTrue);
    expect(data.hasAction(SemanticsAction.tap), isTrue);
    // An empty side opens nothing and announces nothing of the kind.
    expect(
      find.bySemanticsLabel(RegExp('Needs coaching: show all')),
      findsNothing,
    );
    sem.dispose();
  });

  testWidgets('the icon lights up while the pointer is over the box', (
    WidgetTester t,
  ) async {
    await _show(t);
    Color? tint() =>
        t.widget<Icon>(find.byIcon(Icons.open_in_full_rounded)).color;
    final Color? rest = tint();

    final TestGesture mouse = await t.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: const Offset(1199, 1599));
    await mouse.moveTo(t.getCenter(_box('STRENGTHS')));
    await t.pumpAndSettle();
    expect(tint(), isNot(rest));

    await mouse.moveTo(const Offset(1199, 1599));
    await t.pumpAndSettle();
    expect(tint(), rest);
  });

  testWidgets('tapping the filled box lists every category', (
    WidgetTester t,
  ) async {
    await _show(t);
    await t.tap(_box('STRENGTHS'));
    await t.pumpAndSettle();
    expect(
      find.textContaining('measured against the 75% pass mark'),
      findsOneWidget,
    );
  });
}
