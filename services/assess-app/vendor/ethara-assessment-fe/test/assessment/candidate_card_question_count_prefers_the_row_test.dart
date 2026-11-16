// A candidate card's question count follows the ATTEMPT ROW, not a cached zero.
//
// THE BUG THIS EXISTS FOR, reported off a live candidate account. The card on
// "My Assessments" read "6 questions" on a fresh login and "0 questions" the
// moment the candidate opened the exam - or "See my submission" - and came
// back. Nothing about the paper changed; a cache did.
//
// The count was `asm?.totalQuestions ?? ev.serverQuestions ?? 0`, and the trap
// is that ZERO IS NOT NULL. A candidate never loads the assessment list (it is
// a manager route), so `asm` starts null and the row's own `serverQuestions`
// won the `??` chain and read 6. But opening the exam route caches an
// `Assessment` whose `totalQuestions` is 0 - no candidate endpoint sends it a
// question list - and 0 satisfied the FIRST `??`, so it won, permanently, for
// the rest of the session.
//
// It is now `rowQuestions > 0 ? rowQuestions : asmQuestions`, where
// `rowQuestions` is `ev.serverQuestions`: the sitting's own count, which is
// also the more correct source when both are present, since on an independent
// draw this sitting's paper size is not the assessment's. The assessment's
// count is used only when the row carries none.
@TestOn('vm')
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/member/my_assessments_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';

/// A launched assessment the candidate has an available attempt on - which is
/// the bucket that draws the "N questions" line on the card.
Assessment _paper({required int totalQuestions}) => Assessment(
  id: 'A-1',
  name: 'Warehouse Safety',
  state: AsmState.inProgress,
  // `totalQuestions` reads `questions.length`, so a paper the candidate route
  // never sent a question list for is a zero here - which is exactly the
  // cached assessment that produced the bug.
  questions: <Question>[
    for (int i = 0; i < totalQuestions; i++)
      Question.fromJson(<String, dynamic>{
        'id': 'Q$i',
        'name': 'Q$i',
        'question_type': 'mcq',
      }),
  ],
);

/// A candidate's own attempt row. `employeeId` is left as the store's own
/// `meId` so `attemptsForPerson` picks it up, and [serverQuestions] is the
/// per-sitting count the row carries from `total_questions`.
Attempt _row({int? serverQuestions}) => Attempt(
  id: 'E-1',
  assessmentId: 'A-1',
  employeeId: 'P-1',
  token: 'tok-1',
  state: AttemptState.pending,
  serverQuestions: serverQuestions,
);

/// A store on the candidate surface, `meId` at its default 'P-1', holding one
/// attempt and one cached assessment.
AppStore _store({required Attempt attempt, required Assessment asm}) {
  final AppStore s = AppStore();
  s.assessments = <Assessment>[asm];
  s.attempts = <Attempt>[attempt];
  return s;
}

Future<void> _open(WidgetTester t, AppStore s) async {
  t.view.physicalSize = const Size(1600, 2400);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: AssessmentNavScope(
          nav: AssessmentNav(),
          child: MyAssessmentsScreen(store: s),
        ),
      ),
    ),
  );
  await t.pump();
}

void main() {
  testWidgets("the row's own count beats a cached assessment's zero", (
    WidgetTester t,
  ) async {
    // The EXACT reported shape: the row knows it is a six-question paper, and
    // the exam route has cached an assessment whose totalQuestions is 0. The
    // old chain read the 0 and won; the fix reads the 6.
    await _open(
      t,
      _store(
        attempt: _row(serverQuestions: 6),
        asm: _paper(totalQuestions: 0),
      ),
    );

    expect(
      find.textContaining('6 questions'),
      findsOneWidget,
      reason:
          'the sitting carried six; the cached assessment carried zero, and '
          '0 is not null, so the old ?? chain read the zero forever',
    );
    expect(
      find.textContaining('0 questions'),
      findsNothing,
      reason: 'this is the string the candidate saw after opening the exam',
    );
  });

  testWidgets('the assessment fills in when the row carries no count', (
    WidgetTester t,
  ) async {
    // The other half: `rowQuestions` is 0 (the route did not send it), so the
    // fallback is the assessment's own count - it must not now read zero
    // whenever the row is silent.
    await _open(
      t,
      _store(
        attempt: _row(serverQuestions: null),
        asm: _paper(totalQuestions: 8),
      ),
    );

    expect(
      find.textContaining('8 questions'),
      findsOneWidget,
      reason:
          'with no per-sitting count the assessment is the only source left, '
          'and the fallback must still reach it',
    );
  });
}
