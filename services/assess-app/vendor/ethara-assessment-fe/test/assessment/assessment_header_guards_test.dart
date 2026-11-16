// Three header actions on the assessment detail that did more than they should.
//
//   - Cancel on a LIVE paper fired on one click and locked out a candidate
//     mid-exam. It now asks first, like Mark Done, and sends nothing until
//     the operator confirms.
//   - Score All ("Costs one LLM call per answer") was offered on an
//     objective-only paper, because `subjectiveState == pending` is the default
//     on every attempt, and on cancelled papers. It is offered only when the
//     server counts subjective answers awaiting grading, and never on a
//     cancelled or archived paper.
//   - Launch & Invite was offered on an ARCHIVED draft, which the route
//     refuses.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/admin/assessment_detail_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/buttons.dart';

Future<void> _mount(WidgetTester t, AppStore s) async {
  t.view.physicalSize = const Size(1800, 3000);
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
            asmId: 'A-1',
            tab: 'config',
          ),
        ),
      ),
    ),
  );
  await t.pump();
  await t.pump();
  addTearDown(() async {
    await t.pump(const Duration(seconds: 25));
    await t.pumpWidget(const SizedBox.shrink());
  });
}

Btn? _btn(WidgetTester t, bool Function(String label) match) {
  final Finder f = find.byWidgetPredicate(
    (Widget w) => w is Btn && match(w.label),
  );
  return f.evaluate().isEmpty ? null : t.widget<Btn>(f.first);
}

/// Seed mode: no backend, so the header reads exactly the objects given.
AppStore _seeded(
  Assessment asm, {
  List<Attempt> attempts = const <Attempt>[],
}) => AppStore()
  ..assessments = <Assessment>[asm]
  ..attempts = attempts;

/// A submitted attempt carrying only the DEFAULT subjective state.
Attempt _objectiveOnly() => Attempt(
  id: '1',
  assessmentId: 'A-1',
  employeeId: 'P-1',
  token: 'tok',
  state: AttemptState.submitted,
  isLocked: true,
);

void main() {
  group('Cancel on a live paper asks first', () {
    testWidgets('nothing is sent until the operator confirms', (
      WidgetTester t,
    ) async {
      final List<String> paths = <String>[];
      final AppStore s = AppStore(
        api: ApiClient(
          baseUrl: 'http://stub',
          client: MockClient((http.Request req) async {
            paths.add(req.url.path);
            return http.Response(
              jsonEncode(<String, dynamic>{
                'ok': true,
                'data': <String, dynamic>{
                  'id': 'A-1',
                  'name': 'Warehouse Safety',
                  'state': 'in_progress',
                },
              }),
              200,
              headers: <String, String>{'content-type': 'application/json'},
            );
          }),
        ),
      )..caps = Capability.values.toSet();
      await _mount(t, s);

      await t.tap(find.widgetWithText(Btn, 'Cancel'));
      await t.pumpAndSettle();
      expect(find.text('Cancel this assessment?'), findsOneWidget);
      expect(
        paths.where((String p) => p.endsWith('/cancel')),
        isEmpty,
        reason: 'one click must not cancel a live paper',
      );

      await t.tap(find.widgetWithText(Btn, 'Cancel Assessment'));
      await t.pumpAndSettle();
      expect(paths.where((String p) => p.endsWith('/cancel')), hasLength(1));
      // Past the success toast's own dismiss timer.
      await t.pump(const Duration(seconds: 4));
    });
  });

  group('Score All only when subjective answers await grading', () {
    testWidgets('not on an objective-only paper', (WidgetTester t) async {
      await _mount(
        t,
        _seeded(
          Assessment(
            id: 'A-1',
            name: 'Objective Only',
            state: AsmState.inProgress,
            awaitingScoringCount: 0,
          ),
          attempts: <Attempt>[_objectiveOnly()],
        ),
      );
      expect(_btn(t, (String l) => l == 'Score All'), isNull);
    });

    testWidgets('not from the default pending state when no count is sent', (
      WidgetTester t,
    ) async {
      await _mount(
        t,
        _seeded(
          Assessment(id: 'A-1', name: 'No Count', state: AsmState.inProgress),
          attempts: <Attempt>[_objectiveOnly()],
        ),
      );
      expect(_btn(t, (String l) => l == 'Score All'), isNull);
    });

    testWidgets('not on a cancelled paper, even with answers waiting', (
      WidgetTester t,
    ) async {
      await _mount(
        t,
        _seeded(
          Assessment(
            id: 'A-1',
            name: 'Called Off',
            state: AsmState.cancelled,
            awaitingScoringCount: 2,
          ),
        ),
      );
      expect(_btn(t, (String l) => l == 'Score All'), isNull);
    });

    testWidgets('not on an archived paper', (WidgetTester t) async {
      await _mount(
        t,
        _seeded(
          Assessment(
            id: 'A-1',
            name: 'Archived',
            state: AsmState.done,
            active: false,
            awaitingScoringCount: 2,
          ),
        ),
      );
      expect(_btn(t, (String l) => l == 'Score All'), isNull);
    });

    testWidgets('offered when the server counts answers waiting', (
      WidgetTester t,
    ) async {
      await _mount(
        t,
        _seeded(
          Assessment(
            id: 'A-1',
            name: 'Written Answers',
            state: AsmState.inProgress,
            awaitingScoringCount: 2,
          ),
        ),
      );
      expect(_btn(t, (String l) => l == 'Score All')?.onPressed, isNotNull);
    });
  });

  group('Launch & Invite on an archived draft', () {
    bool launch(String l) => l.startsWith('Launch & ');

    testWidgets('is not offered', (WidgetTester t) async {
      await _mount(
        t,
        _seeded(Assessment(id: 'A-1', name: 'Archived Draft', active: false)),
      );
      expect(_btn(t, launch), isNull);
    });

    testWidgets('is still offered on an active draft', (WidgetTester t) async {
      await _mount(t, _seeded(Assessment(id: 'A-1', name: 'Active Draft')));
      expect(_btn(t, launch), isNotNull);
    });
  });
}
