// Browser campaign, 8 Oct 2026: the network goes down at Submit.
//
// BR-D1. The app said "Assessment submitted" for about ten seconds - the retry
// ladder - and then rolled back. The attempt was marked submitted and locked
// before a single request had gone out. Live, it now stays open until the
// server takes the submit: the Submit control shows "Submitting...", and a
// failure leaves the candidate where they pressed it, with Submit to press
// again. The time-up ending follows the same rule.
//
// Ported from stage onto main's per-answer save and `/submit` (no batch).
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
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
import 'package:ethara_assessment/assessment/widgets/feedback.dart';
import 'package:ethara_assessment/assessment/widgets/panel.dart';

const String kToken = 'tok-d1';

http.Response _ok(Map<String, dynamic> data) => http.Response(
  jsonEncode(<String, dynamic>{'ok': true, 'data': data}),
  200,
  headers: <String, String>{'content-type': 'application/json'},
);

/// A live sitting on question 1 of 2. [onSubmit] answers `/submit`; anything
/// else is an empty success.
AppStore _store({
  required Future<http.Response> Function(http.Request req) onSubmit,
  DateTime? deadline,
}) {
  final AppStore s = AppStore(
    api: ApiClient(
      baseUrl: 'https://x.invalid',
      bearer: 't',
      // The whole ladder runs, with no real sleeping.
      sleep: (Duration _) async {},
      client: MockClient((http.Request req) {
        final String route = req.url.path.split('/').last;
        if (route == 'submit') return onSubmit(req);
        return Future<http.Response>.value(_ok(<String, dynamic>{}));
      }),
    ),
    answerDebounce: const Duration(seconds: 30),
    leaveGuard: (void Function()? _) {},
  );
  s.portal = Portal.member;
  s.source = DataSource.live;
  s.meId = '2';
  s.attempts = <Attempt>[
    Attempt.fromJson(<String, dynamic>{
      'id': 1,
      'access_token': kToken,
      'assessment_id': 55,
      'state': 'in_progress',
      'started_at': DateTime.now().toUtc().toIso8601String(),
      'deadline': (deadline ?? DateTime.now().add(const Duration(hours: 1)))
          .toUtc()
          .toIso8601String(),
      'total_questions': 2,
    }),
  ];
  s.assessments = <Assessment>[
    Assessment.fromJson(<String, dynamic>{
      'id': 55,
      'name': 'Paper',
      'state': 'in_progress',
      'duration_minutes': 60,
      'violation_action': 'auto_submit',
      'max_violations': 3,
    }),
  ];
  s.examByToken[kToken] = ExamView.fromJson(<String, dynamic>{
    'outcome': 'question',
    'question': <String, dynamic>{
      'id': '10',
      'index': 1,
      'total': 2,
      'name': 'Q1',
      'prompt': 'Explain.',
      'question_type': 'subjective_rubric',
    },
  });
  s.examReviewByToken[kToken] = const <ExamReviewRow>[
    ExamReviewRow(index: 1, questionId: '10', name: 'Q1', answered: true),
    ExamReviewRow(index: 2, questionId: '11', name: 'Q2', answered: true),
  ];
  return s;
}

/// The network is down: no request gets an answer.
Future<http.Response> _offline(http.Request _) =>
    Future<http.Response>.error(http.ClientException('Failed to fetch'));

List<String> _said(AppStore s) =>
    s.toaster.items.map((ToastMsg m) => m.message).toList();

void main() {
  group(
    'BR-D1: live, the attempt is submitted only when the server says so',
    () {
      test('network down at Submit: never shown submitted, and Submit works '
          'again', () async {
        final AppStore s = _store(onSubmit: _offline);
        bool everDone = false;
        final List<String> narrated = <String>[];
        s.addListener(() => everDone |= s.attemptById('1')!.isDone);
        s.toaster.addListener(() => narrated.addAll(_said(s)));
        s.saveAnswerQuiet('1', '10', const Response(justification: 'mine'));

        final Future<bool> done = s.finishExam('1', force: true);
        // In flight: open, not locked, and the Submit control is busy.
        expect(s.attemptById('1')!.isDone, isFalse);
        expect(s.attemptById('1')!.isLocked, isFalse);
        expect(s.isBusy('submit:1'), isTrue);
        expect(_said(s), <String>['Submitting your exam...']);

        expect(await done, isFalse, reason: 'the server never took it');
        expect(everDone, isFalse, reason: 'not even for a moment');
        expect(s.attemptById('1')!.isLocked, isFalse);
        expect(s.attemptById('1')!.resp['10']!.justification, 'mine');
        expect(s.isBusy('submit:1'), isFalse, reason: 'Submit works again');
        expect(
          narrated.toSet().join(' | '),
          isNot(contains('Assessment submitted')),
        );
        expect(_said(s).join(' | '), contains('NOT submitted'));
        s.dispose();
      });

      test('a submit the server takes settles it then', () async {
        final AppStore s = _store(
          onSubmit: (http.Request _) async => _ok(<String, dynamic>{}),
        );
        final Future<bool> done = s.finishExam('1', force: true);
        expect(s.attemptById('1')!.isDone, isFalse, reason: 'not yet');
        expect(await done, isTrue);
        expect(s.attemptById('1')!.isDone, isTrue);
        expect(_said(s), contains('Assessment submitted'));
        // The re-read that follows, before the store goes.
        await Future<void>.delayed(const Duration(milliseconds: 50));
        s.dispose();
      });

      test(
        'an unknown sitting, or one with no paper, is never submitted',
        () async {
          final AppStore s = _store(
            onSubmit: (http.Request _) async => _ok(<String, dynamic>{}),
          );
          expect(await s.finishExam('nope'), isFalse);
          s.assessments = <Assessment>[];
          expect(await s.finishExam('1', force: true), isFalse);
          expect(s.attemptById('1')!.isDone, isFalse);
          s.dispose();
        },
      );

      test('with no backend it settles at once', () async {
        final AppStore s = AppStore();
        final Attempt open = s.attempts.firstWhere(
          (Attempt a) =>
              a.state == AttemptState.inProgress && a.startedAt != null,
        );
        expect(await s.finishExam(open.id, force: true), isTrue);
        expect(s.attemptById(open.id)!.isDone, isTrue);
        expect(await s.finishExam(open.id), isTrue, reason: 'already done');
        s.dispose();
      });

      testWidgets('on screen: "Submitting..." while it runs, then the review '
          'page again with Submit ready', (WidgetTester t) async {
        final Completer<void> release = Completer<void>();
        final AppStore s = _store(
          onSubmit: (http.Request r) async {
            await release.future;
            return _offline(r);
          },
        );
        final AssessmentNav nav = AssessmentNav();
        t.view.physicalSize = const Size(1400, 1600);
        t.view.devicePixelRatio = 1.0;
        addTearDown(t.view.reset);
        await t.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(),
            home: AssessmentNavScope(
              nav: nav,
              child: ExamScreen(store: s, token: kToken, sub: ExamSub.review),
            ),
          ),
        );
        await t.pump();

        await t.tap(find.text('Submit Assessment'));
        await t.pump();
        expect(
          t.widget<Btn>(find.widgetWithText(Btn, 'Submitting...')).busy,
          isTrue,
        );
        expect(
          t
              .widget<Btn>(find.widgetWithText(Btn, 'Back to Questions'))
              .onPressed,
          isNull,
          reason: 'no edits to a paper that is going out',
        );
        // Nor through the grid: a cell opens nothing while it runs.
        await t.tap(
          find.descendant(of: find.byType(AutoGrid), matching: find.text('2')),
          warnIfMissed: false,
        );
        await t.pump();
        expect(
          nav.current,
          isNot(
            isA<Exam>().having(
              (Exam e) => e.stage,
              'stage',
              ExamStage.question,
            ),
          ),
        );

        release.complete();
        await t.pump();
        await t.pump();

        expect(find.textContaining('Your answers are recorded'), findsNothing);
        final Btn submit = t.widget<Btn>(
          find.widgetWithText(Btn, 'Submit Assessment'),
        );
        expect(submit.busy, isFalse);
        expect(submit.onPressed, isNotNull);
        expect(
          t
              .widget<Btn>(find.widgetWithText(Btn, 'Back to Questions'))
              .onPressed,
          isNotNull,
        );
        expect(
          nav.current,
          isNot(
            isA<Exam>().having(
              (Exam e) => e.stage,
              'stage',
              ExamStage.complete,
            ),
          ),
          reason: 'the completion route is reached only by a real submit',
        );

        // And the paper is reachable again.
        await t.tap(find.text('Back to Questions'));
        await t.pump();
        await t.pump();
        expect(
          nav.current,
          isA<Exam>().having((Exam e) => e.stage, 'stage', ExamStage.question),
        );

        await t.pumpWidget(const SizedBox());
        await t.pump(const Duration(minutes: 1));
        s.dispose();
      });

      testWidgets('time up with the network down: the overlay stays, with its '
          'button', (WidgetTester t) async {
        final AppStore s = _store(
          onSubmit: _offline,
          deadline: DateTime.now().subtract(const Duration(seconds: 5)),
        );
        t.view.physicalSize = const Size(1400, 1600);
        t.view.devicePixelRatio = 1.0;
        addTearDown(t.view.reset);
        await t.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(),
            home: AssessmentNavScope(
              nav: AssessmentNav(),
              child: ExamScreen(store: s, token: kToken, sub: ExamSub.question),
            ),
          ),
        );
        await t.pump(const Duration(seconds: 3));
        expect(find.text('Time is up'), findsOneWidget);

        await t.tap(find.text('See my submission'));
        await t.pump();
        await t.pump();

        expect(find.text('Time is up'), findsOneWidget);
        expect(find.text('See my submission'), findsOneWidget);
        expect(s.attemptById('1')!.isDone, isFalse);

        await t.pumpWidget(const SizedBox());
        await t.pump(const Duration(minutes: 1));
        s.dispose();
      });

      testWidgets('time up, and the server takes it: the overlay comes down on '
          'the completion page', (WidgetTester t) async {
        final Completer<void> release = Completer<void>();
        final AppStore s = _store(
          onSubmit: (http.Request _) async {
            await release.future;
            return _ok(<String, dynamic>{});
          },
          deadline: DateTime.now().subtract(const Duration(seconds: 5)),
        );
        final AssessmentNav nav = AssessmentNav();
        t.view.physicalSize = const Size(1400, 1600);
        t.view.devicePixelRatio = 1.0;
        addTearDown(t.view.reset);
        await t.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(),
            home: AssessmentNavScope(
              nav: nav,
              child: ExamScreen(store: s, token: kToken, sub: ExamSub.question),
            ),
          ),
        );
        await t.pump(const Duration(seconds: 3));
        await t.tap(find.text('See my submission'));
        await t.pump();
        expect(find.text('Time is up'), findsOneWidget, reason: 'still out');
        expect(s.attemptById('1')!.isDone, isFalse);

        release.complete();
        await t.pump();
        await t.pump();
        expect(find.text('Time is up'), findsNothing);
        expect(
          nav.current,
          isA<Exam>().having((Exam e) => e.stage, 'stage', ExamStage.complete),
        );

        await t.pumpWidget(const SizedBox());
        await t.pump(const Duration(minutes: 1));
        s.dispose();
      });
    },
  );
}
