// The admin can tell whether the AI watch ran on the candidate's device, and
// sees the AI count apart from the regular violations.
//
// `ai_status` is what the candidate's browser reported (`running`, `failed`).
// Without a line for it, "no AI violations" read the same as "the AI never
// started", which are opposite findings about a sitting. The line is the
// candidate's browser's own word, so it says so: a tampered client can report
// "running". Eye movement is gone (19 Oct): a sitting from before that
// reported `running_gaze` or `gaze_failed` had the AI running, and its review
// flags are no longer shown.
@TestOn('vm')
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/admin/attempt_detail_screen.dart';
import 'package:ethara_assessment/assessment/screens/admin/candidate_detail_screen.dart';
import 'package:ethara_assessment/assessment/screens/admin/response_detail_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/marks.dart';
import 'package:ethara_assessment/assessment/widgets/panel.dart';

/// A seed store with one sitting on an AI paper (AI cap 2, auto-submit).
AppStore _seeded(Map<String, dynamic> extra, {bool ai = true}) => AppStore()
  ..people = <Person>[const Person(id: 'p1', name: 'Asha', email: 'a@x.io')]
  ..assessments = <Assessment>[
    Assessment.fromJson(<String, dynamic>{
      'id': 'a1',
      'name': 'Warehouse Safety',
      'state': 'done',
      'rules': <String, dynamic>{'ai_proctor': ai},
      'max_violations': 5,
      'ai_max_violations': 2,
      'ai_violation_action': 'auto_submit',
      'questions': <dynamic>[
        <String, dynamic>{
          'id': 'q1',
          'name': 'Explain the defect',
          'question_type': 'subjective_rubric',
        },
      ],
    }),
  ]
  ..attempts = <Attempt>[
    Attempt.fromJson(<String, dynamic>{
      'id': '90',
      'assessment_id': 'a1',
      'candidate': <String, dynamic>{'id': 'p1', 'name': 'Asha'},
      'state': 'submitted',
      'answers': <dynamic>[
        <String, dynamic>{'question_id': 'q1', 'justification': 'An answer.'},
      ],
      ...extra,
    }),
  ];

Future<void> _mount(WidgetTester t, Widget child) async {
  t.view.physicalSize = const Size(1800, 3000);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData.light(),
      home: Scaffold(
        body: AssessmentNavScope(nav: AssessmentNav(), child: child),
      ),
    ),
  );
  await t.pumpAndSettle();
}

Widget _attempt(AppStore s) =>
    AttemptDetailScreen(store: s, portal: Portal.admin, attemptId: '90');

/// The value a KPI card with [label] shows.
Finder _kpi(String label, String value) => find.byWidgetPredicate(
  (Widget w) => w is Kpi && w.label == label && w.value == value,
);

void main() {
  testWidgets('a paper without the AI watch keeps its four cards', (
    WidgetTester t,
  ) async {
    await _mount(t, _attempt(_seeded(<String, dynamic>{}, ai: false)));
    expect(find.byType(Kpi), findsNWidgets(4));
  });

  group('the attempt page', () {
    // Both meant the face and phone checks were running.
    for (final String old in <String>['running_gaze', 'gaze_failed']) {
      testWidgets('an older sitting that reported $old reads as AI running', (
        WidgetTester t,
      ) async {
        await _mount(t, _attempt(_seeded(<String, dynamic>{'ai_status': old})));
        expect(
          find.text(
            "AI proctoring: running (reported by the candidate's device)",
          ),
          findsOneWidget,
        );
        expect(find.textContaining('Eye tracking'), findsNothing);
      });
    }

    testWidgets('AI that failed to start says so', (WidgetTester t) async {
      await _mount(
        t,
        _attempt(_seeded(<String, dynamic>{'ai_status': 'failed'})),
      );
      expect(
        find.text(
          "AI proctoring could not start (reported by the candidate's device)",
        ),
        findsOneWidget,
      );
    });

    testWidgets('AI running says so', (WidgetTester t) async {
      await _mount(
        t,
        _attempt(_seeded(<String, dynamic>{'ai_status': 'running'})),
      );
      expect(
        find.text(
          "AI proctoring: running (reported by the candidate's device)",
        ),
        findsOneWidget,
      );
    });

    testWidgets('no report draws no line', (WidgetTester t) async {
      await _mount(t, _attempt(_seeded(<String, dynamic>{})));
      expect(find.textContaining('Eye tracking'), findsNothing);
      expect(find.textContaining('could not start'), findsNothing);
      expect(find.textContaining('AI proctoring:'), findsNothing);
    });

    testWidgets('AI violations are counted apart; old review flags are not '
        'shown', (WidgetTester t) async {
      await _mount(
        t,
        _attempt(
          _seeded(<String, dynamic>{
            'violation_count': 1,
            'ai_violation_count': 2,
            // A server from before 19 Oct may still send these.
            'review_flag_count': 3,
            'review_flags': <dynamic>[
              <String, dynamic>{
                'reason': 'Looking away from the screen',
                'at': '2026-10-07 10:00:00',
              },
            ],
          }),
        ),
      );
      expect(_kpi('Violations', '1'), findsOneWidget);
      expect(_kpi('AI violations', '2'), findsOneWidget);
      expect(find.text('Review flags'), findsNothing);
      expect(
        find.textContaining('Review flags', findRichText: true),
        findsNothing,
      );
      expect(find.byType(Kpi), findsNWidgets(5));
      // Five cards on an AI paper, one row on a wide screen.
      final Set<double> tops = find
          .byType(Kpi)
          .evaluate()
          .map((Element e) => t.getTopLeft(find.byWidget(e.widget)).dy)
          .toSet();
      expect(tops.length, 1, reason: 'a card wrapped onto a row of its own');
      // The notice draws its strong line inside one rich text.
      expect(
        find.textContaining(
          '2 AI proctoring violations recorded.',
          findRichText: true,
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          '1 proctoring violation recorded.',
          findRichText: true,
        ),
        findsOneWidget,
      );
    });

    testWidgets('an AI auto-submit names the AI cap', (WidgetTester t) async {
      await _mount(
        t,
        _attempt(
          _seeded(<String, dynamic>{
            'ai_violation_count': 2,
            'ai_violation_limit_breached': true,
            'auto_submitted': true,
            'auto_submit_reason': 'ai_violation',
          }),
        ),
      );
      expect(find.text('AI Violation Limit Breached - 2 / 2'), findsOneWidget);
      expect(
        find.text('Violation Limit Breached - 0 / 5'),
        findsNothing,
        reason: 'the regular count is under its own cap',
      );
      expect(_kpi('Auto-submitted', 'AI proctor'), findsOneWidget);
    });
  });

  testWidgets('the answer page side panel shows the same', (
    WidgetTester t,
  ) async {
    await _mount(
      t,
      ResponseDetailScreen(
        store: _seeded(<String, dynamic>{
          'ai_violation_count': 2,
          'ai_violation_limit_breached': true,
          'review_flag_count': 3,
          'ai_status': 'running_gaze',
        }),
        attemptId: '90',
        questionId: 'q1',
      ),
    );
    expect(find.text('AI violations'), findsOneWidget);
    expect(find.text('AI Violation Limit Breached - 2 / 2'), findsOneWidget);
    expect(find.text('Review flags'), findsNothing);
    expect(
      find.text("AI proctoring: running (reported by the candidate's device)"),
      findsOneWidget,
    );
  });

  testWidgets('the answer page side panel: an AI count under its cap', (
    WidgetTester t,
  ) async {
    await _mount(
      t,
      ResponseDetailScreen(
        store: _seeded(<String, dynamic>{'ai_violation_count': 1}),
        attemptId: '90',
        questionId: 'q1',
      ),
    );
    expect(find.text('AI violations'), findsOneWidget);
    expect(find.textContaining('AI Violation Limit Breached'), findsNothing);
    expect(find.widgetWithText(Mono, '1'), findsWidgets);
  });

  testWidgets('the candidate page badges an AI breach, and no review flags', (
    WidgetTester t,
  ) async {
    await _mount(
      t,
      CandidateDetailScreen(
        store: _seeded(<String, dynamic>{
          'ai_violation_count': 2,
          'ai_violation_limit_breached': true,
          'review_flag_count': 3,
        }),
        personId: 'p1',
      ),
    );
    expect(find.text('Review 3'), findsNothing);
    expect(find.text('AI Violation Limit Breached'), findsOneWidget);
  });
}
