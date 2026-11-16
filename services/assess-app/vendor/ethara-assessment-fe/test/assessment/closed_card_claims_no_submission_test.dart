// A closed assessment the candidate never sat says exactly that, and nothing
// more.
//
// THE BUG THIS EXISTS FOR, reported off a live console. A candidate whose
// assessment was closed before they sat it saw BOTH lines on the same card:
//
//   "Awaiting release. Your answers are recorded and marked; the marks are
//    held until an administrator releases them."
//   "This assessment has been closed/expired without a submission from you."
//
// The first is false - there were no answers - and the two contradict each
// other. Worse, it was unclearable: an administrator released the results and
// the sentence stayed, because there is no submission to release, so
// `resultsReleased` never flips and the branch it guarded ran forever.
//
// The cause is a deliberate mapping doing its job somewhere it should not
// reach. The wire files this attempt under `state: "closed"`;
// `AttemptState.parse` maps `closed` to `submitted` ON PURPOSE, so that a
// released result on a closed assessment still renders rather than reading as
// unstarted; and `Attempt.isDone` is `state == submitted || isLocked`. So
// `isDone` is true for somebody who did nothing, and every branch keyed on it
// spoke as if they had.
//
// The card now keys on the BUCKET instead, which is safe by construction: the
// server only files an attempt under `closed` after `completed` has already
// failed to match, so a candidate who did sit it is never in this branch.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/member/my_assessments_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';

Widget mount(Widget child, AssessmentNav nav) => MaterialApp(
  theme: ThemeData.dark(),
  home: Scaffold(
    body: AssessmentNavScope(nav: nav, child: child),
  ),
);

Future<void> setSurface(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1600, 2600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// One attempt built from the payload `serializers.attempt` really sends for
/// this case, parsed by the app's own `fromJson`.
///
/// Built from JSON rather than `copyWith` deliberately: `serverBucket` is a
/// server-derived field and `copyWith` takes no `server*` parameters by design,
/// so the only honest way to reach this state is the wire shape that produces
/// it - which is also the path the bug travelled.
Attempt closedAttempt({required bool released, required String assessmentId}) =>
    Attempt.fromJson(<String, dynamic>{
      'id': 'EV-CLOSED-1',
      'assessment_id': assessmentId,
      'name': 'new test gen test',
      // THE KEY LINE. The server files a never-sat attempt on a closed
      // assessment under the `closed` bucket, and it arrives on `state`.
      'state': 'closed',
      'progress': <String, dynamic>{'answered': 0, 'total': 5, 'percent': 0},
      'duration_minutes': 45,
      'results_released': released,
    });

AppStore closedAttemptStore({required bool released}) {
  final AppStore s = AppStore();
  final Attempt first = s.attemptsForPerson(s.meId).first;
  s.attempts = <Attempt>[
    closedAttempt(released: released, assessmentId: first.assessmentId),
  ];
  return s;
}

const String kAwaiting =
    'Awaiting release. Your answers are recorded; your result is held until '
    'an administrator releases it.';
const String kClosed =
    'This assessment has been closed/expired without a submission from you.';

void main() {
  testWidgets('a closed card does not claim answers were recorded', (
    WidgetTester tester,
  ) async {
    await setSurface(tester);
    await tester.pumpWidget(
      mount(
        MyAssessmentsScreen(store: closedAttemptStore(released: false)),
        AssessmentNav(),
      ),
    );
    await tester.pump();

    expect(
      find.textContaining('Awaiting release'),
      findsNothing,
      reason:
          'the candidate submitted nothing, so there is nothing awaiting '
          'release - and this sentence could never be cleared',
    );
    expect(find.text(kClosed), findsOneWidget);
  });

  testWidgets('a released flag on a closed card changes nothing either', (
    WidgetTester tester,
  ) async {
    // BELT AND BRACES, and worth being precise about why.
    //
    // When the operator "released the results" and the card did not change,
    // this is NOT the state they landed in: the release route filters
    // `state == "submitted"`, so an attempt nobody sat is skipped entirely and
    // `results_released` stays false for good - which is the case above, and
    // is exactly why the sentence was unclearable rather than merely wrong.
    //
    // This pins the other half anyway: even if a closed attempt somehow
    // arrived carrying the flag, the card must still not claim a submission.
    await setSurface(tester);
    await tester.pumpWidget(
      mount(
        MyAssessmentsScreen(store: closedAttemptStore(released: true)),
        AssessmentNav(),
      ),
    );
    await tester.pump();

    expect(find.textContaining('Awaiting release'), findsNothing);
    expect(find.text(kClosed), findsOneWidget);
  });

  testWidgets('a genuinely submitted attempt still awaits release', (
    WidgetTester tester,
  ) async {
    // The line must not have been deleted outright - a candidate who DID sit
    // an assessment is owed it.
    await setSurface(tester);
    final AppStore s = AppStore();
    final Attempt first = s.attemptsForPerson(s.meId).first;
    s.attempts = <Attempt>[
      Attempt.fromJson(<String, dynamic>{
        'id': 'EV-DONE-1',
        'assessment_id': first.assessmentId,
        'name': 'test assessment',
        'state': 'completed',
        'progress': <String, dynamic>{
          'answered': 5,
          'total': 5,
          'percent': 100,
        },
        'duration_minutes': 45,
        'results_released': false,
      }),
    ];

    await tester.pumpWidget(
      mount(MyAssessmentsScreen(store: s), AssessmentNav()),
    );
    await tester.pump();

    expect(
      find.textContaining('Awaiting release'),
      findsOneWidget,
      reason: 'a real submission still has marks being held',
    );
  });
}
