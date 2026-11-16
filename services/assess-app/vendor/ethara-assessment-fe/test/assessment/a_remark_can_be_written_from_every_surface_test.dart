// TEMPORARY - verification only, deleted after the run.
@TestOn('vm')
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/admin/attempt_detail_screen.dart';
import 'package:ethara_assessment/assessment/screens/admin/candidate_detail_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';

Widget mount(Widget child, AssessmentNav nav) => MaterialApp(
  theme: ThemeData.dark(),
  home: Scaffold(body: AssessmentNavScope(nav: nav, child: child)),
);

AppStore seeded() {
  final AppStore s = AppStore();
  s.people = <Person>[
    const Person(id: 'p1', name: 'Anita Rao', email: 'anita@example.com'),
  ];
  s.assessments = <Assessment>[
    Assessment.fromJson(<String, dynamic>{
      'id': 'a1',
      'name': 'ETP Assessment Pro',
      'state': 'done',
      'questions': <dynamic>[],
    }),
  ];
  s.attempts = <Attempt>[
    Attempt.fromJson(<String, dynamic>{
      'id': '80',
      'assessment_id': 'a1',
      'candidate': <String, dynamic>{'id': 'p1', 'name': 'Anita Rao'},
      'state': 'submitted',
      'answered_count': 0,
      'total_questions': 0,
      'results_released': true,
      'result': 'pass',
      'score_marks': '0 / 0',
    }),
  ];
  return s;
}

Future<void> wide(WidgetTester t) async {
  t.view.physicalSize = const Size(1800, 3000);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
}

void main() {
  testWidgets('attempt detail: header Add remark writes, panel Edit reopens', (
    WidgetTester t,
  ) async {
    await wide(t);
    final AppStore s = seeded();
    await t.pumpWidget(
      mount(
        AttemptDetailScreen(store: s, portal: Portal.admin, attemptId: '80'),
        AssessmentNav(),
      ),
    );
    await t.pumpAndSettle();

    expect(find.text('Add remark'), findsOneWidget);
    expect(find.text('Internal Remark'), findsNothing);

    await t.tap(find.text('Add remark'));
    await t.pumpAndSettle();
    expect(find.textContaining('Add a remark on Anita Rao'), findsOneWidget);

    await t.enterText(find.byType(TextField).first, 'Left the room twice.');
    await t.pumpAndSettle();
    await t.tap(find.text('Save Remark'));
    await t.pumpAndSettle();

    expect(s.attemptById('80')!.candidateFlag.remark, 'Left the room twice.');
    expect(
      s.attemptById('80')!.candidateFlag.flagged,
      isFalse,
      reason: 'saving a remark must not raise the flag',
    );
    expect(find.text('Internal Remark'), findsOneWidget);
    expect(find.text('Add remark'), findsNothing);
    expect(find.text('Edit remark'), findsOneWidget);
    expect(find.byIcon(Icons.mode_comment_outlined), findsOneWidget);

    await t.tap(find.text('Edit remark'));
    await t.pumpAndSettle();
    expect(find.textContaining('Edit the remark on Anita Rao'), findsOneWidget);
  });

  testWidgets('candidate detail: the row glyph writes a remark in place', (
    WidgetTester t,
  ) async {
    await wide(t);
    final AppStore s = seeded();
    final AssessmentNav nav = AssessmentNav();
    await t.pumpWidget(
      mount(CandidateDetailScreen(store: s, personId: 'p1'), nav),
    );
    await t.pumpAndSettle();

    expect(find.text('REMARKS'), findsOneWidget);
    expect(find.byIcon(Icons.mode_comment_outlined), findsOneWidget);

    await t.tap(find.byIcon(Icons.mode_comment_outlined), warnIfMissed: false);
    await t.pumpAndSettle();
    expect(find.textContaining('Add a remark on Anita Rao'), findsOneWidget);

    await t.enterText(find.byType(TextField).first, 'Second sitting flagged.');
    await t.pumpAndSettle();
    await t.tap(find.text('Save Remark'));
    await t.pumpAndSettle();

    expect(s.attemptById('80')!.candidateFlag.remark, 'Second sitting flagged.');
    expect(s.attemptById('80')!.candidateFlag.flagged, isFalse);
    expect(find.textContaining('Second sitting flagged.'), findsWidgets);
    expect(
      nav.current,
      isNot(isA<AttemptDetail>()),
      reason: 'the remark tap must not also open the sitting',
    );

    // And the text itself reopens the sheet for an edit.
    await t.tap(find.textContaining('Second sitting flagged.').first,
        warnIfMissed: false);
    await t.pumpAndSettle();
    expect(find.textContaining('Edit the remark on Anita Rao'), findsOneWidget);
    expect(
      nav.current,
      isNot(isA<AttemptDetail>()),
      reason: 'editing the text must not navigate either',
    );
  });

  testWidgets('candidate detail: a read-only Manager gets no glyph and no tap',
      (WidgetTester t) async {
    await wide(t);
    final AppStore s = seeded();
    s.caps = <Capability>{Capability.release};
    s.attempts = <Attempt>[
      s.attempts.first.copyWith(
        candidateFlag: const CandidateFlag(remark: 'Read only sees this.'),
      ),
    ];
    await t.pumpWidget(
      mount(CandidateDetailScreen(store: s, personId: 'p1'), AssessmentNav()),
    );
    await t.pumpAndSettle();

    expect(find.textContaining('Read only sees this.'), findsOneWidget);
    expect(find.byIcon(Icons.mode_comment_outlined), findsNothing);
    await t.tap(find.textContaining('Read only sees this.'),
        warnIfMissed: false);
    await t.pumpAndSettle();
    expect(find.textContaining('the remark on Anita Rao'), findsNothing,
        reason: 'no sheet for a rung that cannot write');
  });
}
