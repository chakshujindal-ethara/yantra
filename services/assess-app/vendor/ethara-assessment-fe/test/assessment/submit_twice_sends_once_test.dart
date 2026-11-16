// A-052: two quick taps on "Submit Assessment" submit the paper once.
//
// `finishExam` had no done / in-flight guard, so a second tap that landed
// before the rebuild re-sent every answer and POSTed `/submit` again.
//
// And a double-click on "Submit Anyway" in the confirm sheet popped the sheet
// AND the exam page under it: a white page with nothing in it.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/exam/exam_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/buttons.dart';

const String kToken = 'tok-a052';

/// The server's still-open row, as a refresh would hand it back.
Attempt _openRow() => Attempt.fromJson(<String, dynamic>{
  'id': 7,
  'access_token': kToken,
  'assessment_id': 21,
  'state': 'in_progress',
  'started_at': DateTime.now().toUtc().toIso8601String(),
  'deadline': DateTime.now()
      .add(const Duration(hours: 1))
      .toUtc()
      .toIso8601String(),
});

AppStore _store(List<String> submits, {Future<void>? held}) {
  final AppStore s = AppStore(
    api: ApiClient(
      baseUrl: 'http://stub',
      client: MockClient((http.Request req) async {
        if (req.url.path.endsWith('/submit')) {
          submits.add(req.url.path);
          await held;
        }
        return http.Response(
          jsonEncode(<String, dynamic>{'ok': true, 'data': <String, dynamic>{}}),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }),
      bearer: 't',
    ),
  );
  s.portal = Portal.member;
  s.source = DataSource.live;
  s.meId = '2';
  s.attempts = <Attempt>[_openRow()];
  s.assessments = <Assessment>[
    Assessment.fromJson(<String, dynamic>{
      'id': 21,
      'name': 'sample test',
      'state': 'in_progress',
      'duration_minutes': 60,
    }),
  ];
  return s;
}

Future<void> _open(WidgetTester t, AppStore s) async {
  t.view.physicalSize = const Size(1400, 2400);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: AssessmentNavScope(
        nav: AssessmentNav(),
        child: ExamScreen(store: s, token: kToken, sub: ExamSub.review),
      ),
    ),
  );
  await t.pump();
}

Future<void> _settle(WidgetTester t) async {
  await t.pump();
  await t.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 60)),
  );
  await t.pump();
}

void main() {
  testWidgets('two quick taps send one submit', (WidgetTester t) async {
    final List<String> submits = <String>[];
    // Held open, so the submit is still in flight below.
    final Completer<void> land = Completer<void>();
    final AppStore s = _store(submits, held: land.future);
    // Every question answered, so Submit goes straight through - no sheet.
    s.examReviewByToken[kToken] = const <ExamReviewRow>[
      ExamReviewRow(index: 1, questionId: '10', name: 'Q1', answered: true),
    ];
    await _open(t, s);

    // No frame between them: the second lands on the same button.
    await t.tap(find.text('Submit Assessment'));
    await t.tap(find.text('Submit Assessment'), warnIfMissed: false);
    await _settle(t);
    expect(submits, hasLength(1));

    // A refresh puts the server's still-open row back while the submit is in
    // flight, and the sitting is open anyway until the server takes it (BR-D1),
    // so the review - and its button - stays on screen. `isDone` cannot stop
    // a press now; the button has to say it is busy.
    s.attempts = <Attempt>[_openRow()];
    t.element(find.byType(ExamScreen)).markNeedsBuild();
    await t.pump();
    expect(
      t.widget<Btn>(find.widgetWithText(Btn, 'Submitting...')).busy,
      isTrue,
      reason: 'inert while the submit is in flight (A-052)',
    );
    await t.tap(find.text('Submitting...'), warnIfMissed: false);
    await _settle(t);
    expect(submits, hasLength(1));

    land.complete();
    await _settle(t);
    await t.pump(const Duration(seconds: 4));
  });

  testWidgets('a double-click on "Submit Anyway" closes the sheet, not the '
      'exam', (WidgetTester t) async {
    final SemanticsHandle sem = t.ensureSemantics();
    final List<String> submits = <String>[];
    // Held, so the page is read while the submit is still in flight.
    final Completer<void> land = Completer<void>();
    final AppStore s = _store(submits, held: land.future);
    // One gap, so Submit asks first.
    s.examReviewByToken[kToken] = const <ExamReviewRow>[
      ExamReviewRow(index: 1, questionId: '10', name: 'Q1', answered: true),
      ExamReviewRow(index: 2, questionId: '11', name: 'Q2', answered: false),
    ];
    await _open(t, s);

    await t.tap(find.text('Submit Assessment'));
    await t.pumpAndSettle();
    expect(find.text('Submit Anyway'), findsOneWidget);

    // THROUGH THE SEMANTICS TREE, as a browser with semantics on delivers a
    // click: each one is a tap action, which the Navigator's between-frames
    // pointer absorber never sees. A double-click is two, before the next
    // frame.
    final SemanticsNode anyway = t.getSemantics(find.text('Submit Anyway'));
    expect(anyway.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    anyway.owner!.performAction(anyway.id, SemanticsAction.tap);
    anyway.owner!.performAction(anyway.id, SemanticsAction.tap);
    await t.pump();
    await t.pump(const Duration(seconds: 1));

    expect(
      find.byType(ExamScreen),
      findsOneWidget,
      reason: 'the second click popped the exam page too: a blank screen',
    );
    expect(find.text('Submit Anyway'), findsNothing);
    // The page under the sheet, still submitting: the completion view waits
    // for the server's answer (BR-D1).
    expect(find.text('Submitting...'), findsOneWidget);
    expect(submits, hasLength(1));

    land.complete();
    await _settle(t);
    await t.pump(const Duration(seconds: 4));
    sem.dispose();
  });
}
