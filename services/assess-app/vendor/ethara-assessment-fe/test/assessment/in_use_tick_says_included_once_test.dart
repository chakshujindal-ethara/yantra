// The in-use tick says whether the row is in the paper - once, and truthfully.
//
// THE BUG THIS EXISTS FOR, found with a screen reader on a launched paper. The
// Selected Questions tab lists the whole generator pool once a paper is out of
// draft - the rows the operator EXCLUDED as well as the rows it draws, dimmed
// but legible, so an exclusion can be undone. Each row's tick is a Semantics
// checkbox, and its label was the constant '$name included in this paper'
// regardless of state.
//
// That was survivable while the tab listed only the drawn rows - the sentence
// was then always true. On a launched paper it is not: half the rows are not
// included. And because the frozen tick wraps itself in a Tooltip carrying the
// OPPOSITE message, a reader on an excluded row heard, in one breath,
// "X is not part of this paper" (the tooltip) immediately followed by
// "X included in this paper" (the label). Two contradictory readings of one
// row.
//
// The fix is two things at once, both pinned here:
//   1. the label is now state-dependent - 'is part of this paper' when ticked,
//      'is not part of this paper' when not - and worded identically to the
//      tooltip so the two can never disagree again;
//   2. BOTH Tooltips set `excludeFromSemantics: true`, so the tooltip no longer
//      contributes a second, competing announcement.
//
// The old string 'included in this paper' must therefore appear NOWHERE on the
// screen - not as a label, not as a tooltip message.
@TestOn('vm')
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/admin/assessment_detail_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';

/// One pool row as `assessment_pool` sends it, ticked or not.
Map<String, dynamic> _q(int id, {required bool inUse}) => <String, dynamic>{
  'id': id,
  'name': 'Q$id',
  'question_type': 'mcq',
  'difficulty': 'medium',
  'sequence': id,
  'active': true,
  'state': 'approved',
  'in_use': inUse,
};

/// A LAUNCHED assessment (`in_progress`) whose pool has one drawn row (Q1) and
/// one excluded row (Q2). Launched is the state where the pool lists the
/// excluded rows too, which is the whole precondition for the bug.
Map<String, dynamic> _detail() => <String, dynamic>{
  'id': '7',
  'name': 'test_cj',
  'state': 'in_progress',
  'duration_minutes': 45,
  'generator': <String, dynamic>{'id': 3, 'name': 'SOP alpha'},
  'pool': <Map<String, dynamic>>[
    _q(1, inUse: true),
    _q(2, inUse: false),
  ],
};

AppStore _store() => AppStore(
  api: ApiClient(
    baseUrl: 'http://x',
    client: MockClient(
      (http.Request _) async => http.Response(
        jsonEncode(<String, dynamic>{'ok': true, 'data': _detail()}),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      ),
    ),
  ),
);

Future<void> _open(WidgetTester t, AppStore s) async {
  t.view.physicalSize = const Size(1600, 3200);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: AssessmentNavScope(
          nav: AssessmentNav(),
          child: AssessmentDetailScreen(
            store: s,
            portal: Portal.admin,
            asmId: '7',
            tab: 'questions',
          ),
        ),
      ),
    ),
  );
  await t.pump();
  await t.pump(const Duration(milliseconds: 50));
}

/// Every `Semantics` label the screen declares, in tree order.
List<String> _semanticsLabels(WidgetTester t) => t
    .widgetList<Semantics>(find.byType(Semantics))
    .map((Semantics w) => w.properties.label ?? '')
    .where((String s) => s.isNotEmpty)
    .toList();

/// Every `Tooltip` message the screen declares.
List<String> _tooltipMessages(WidgetTester t) => t
    .widgetList<Tooltip>(find.byType(Tooltip))
    .map((Tooltip w) => w.message ?? '')
    .where((String s) => s.isNotEmpty)
    .toList();

void main() {
  testWidgets('a drawn row is announced as part of the paper', (
    WidgetTester t,
  ) async {
    await _open(t, _store());

    // Guard the fixture: the launched pool has to have actually rendered both
    // rows, or the label assertions below would pass or fail for the wrong
    // reason.
    expect(find.text('Q1'), findsOneWidget);
    expect(find.text('Q2'), findsOneWidget);

    // The tick's own Semantics label - read off the widget it is declared on,
    // which is the exact string the fix now derives from the row's state.
    expect(
      _semanticsLabels(t),
      contains('Q1 is part of this paper'),
      reason: 'Q1 is ticked, so the checkbox label must say it is included',
    );
  });

  testWidgets('an excluded row is announced as NOT part of the paper', (
    WidgetTester t,
  ) async {
    await _open(t, _store());

    expect(find.text('Q2'), findsOneWidget);

    expect(
      _semanticsLabels(t),
      contains('Q2 is not part of this paper'),
      reason:
          'Q2 is excluded; the label used to say "included" here, contradicting '
          'the tooltip on the same row',
    );
  });

  testWidgets('the old constant "included in this paper" is gone everywhere', (
    WidgetTester t,
  ) async {
    await _open(t, _store());

    // Guard the fixture first - an empty screen would pass this vacuously.
    expect(find.text('Q1'), findsOneWidget);

    // Not as a Semantics label, and not as a Tooltip message. The tooltip now
    // sets excludeFromSemantics AND its own copy changed, and the label no
    // longer uses this wording at all - so the double-announcement has no
    // surviving source anywhere on the screen.
    final Iterable<String> everyString = <String>[
      ..._semanticsLabels(t),
      ..._tooltipMessages(t),
    ];
    for (final String s in everyString) {
      expect(
        s,
        isNot(contains('included in this paper')),
        reason: 'this is the label that fired on top of the opposite tooltip; '
            'found it on: "$s"',
      );
    }
    // Guard the guard: the strings we are scanning are really the tick's, so
    // the loop above is not vacuously true.
    expect(everyString, contains('Q1 is part of this paper'));
  });

  testWidgets('the tick tooltip no longer speaks to a screen reader', (
    WidgetTester t,
  ) async {
    await _open(t, _store());
    expect(find.text('Q1'), findsOneWidget);

    // THE OTHER HALF OF THE FIX. The double-announcement was the tooltip
    // contributing its message to the semantics tree; every tick tooltip must
    // now set excludeFromSemantics, so the checkbox label is the only thing a
    // reader hears on the row.
    final Iterable<Tooltip> paperTips = t
        .widgetList<Tooltip>(find.byType(Tooltip))
        .where((Tooltip w) => (w.message ?? '').contains('this paper'));
    expect(
      paperTips,
      isNotEmpty,
      reason: 'a launched row still carries a pointer tooltip - guard the guard',
    );
    for (final Tooltip tip in paperTips) {
      expect(
        tip.excludeFromSemantics,
        isTrue,
        reason: 'a tooltip in the tree announces a second time; on "'
            '${tip.message}" it read on top of the checkbox label',
      );
    }
  });
}
