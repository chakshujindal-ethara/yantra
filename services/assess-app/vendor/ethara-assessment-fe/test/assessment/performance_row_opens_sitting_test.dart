// A candidate opens a past sitting from My performance.
//
// WHY THIS EXISTS. The Score breakdown table named every sitting the candidate
// had submitted, with the mark and the verdict beside it, and clicked nowhere -
// `GridLink.plain`, "this row has no destination". The destination existed the
// whole time: My assessments has opened the same review from its completed
// bucket since it was written (`my_assessments_screen.dart:348`). So the answer
// sheet was reachable only from the screen you were not on, and the table that
// most obviously invited a click was the one that ignored it.
//
// THE OTHER HALF, and the reason this drives `AssessmentSection` rather than
// mounting `ExamScreen` directly the way `answer_review_test.dart` does: the
// hop from a candidate screen INTO the runner had no coverage at all. Every
// exam test mounts the runner as `MaterialApp.home` with a token already in
// hand, which skips the navigation entirely. This walks the path a person
// walks - performance table, tap the row, land on the answers - so a
// regression in the section's routing shows up here rather than in a browser.
//
// The dead-link gate is asserted against BY NAME. It is the failure this
// codebase keeps producing: a candidate never loads an Assessment record
// (`/api/v1/assessments` is a manager route), and four separate screens have
// at some point gated on one and told her a perfectly good link was broken.
// See the headers of `answer_review_test.dart` and
// `exam_start_from_list_test.dart` for instances three and four.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ethara_assessment/assessment/assessment_section.dart';
import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/data_grid.dart';

const String kToken = '00000000-0000-4000-8000-000000000001';

/// The wording the broken screen shows. Asserted by name so a regression
/// cannot pass by rendering the same gate with different copy.
const String kDeadLink = 'This link does not work';

const String kAssessmentName = 'Forklift Safety - Induction E2E';

/// `/api/v1/exam/<token>/answers`, in the shape the live module answers with.
Map<String, dynamic> _answersPayload({required bool released}) =>
    <String, dynamic>{
      'assessment': <String, dynamic>{'id': 18, 'name': kAssessmentName},
      'result': <String, dynamic>{
        'released': released,
        'status': released ? 'released' : 'awaiting_results',
        if (released) 'score_marks': '1 / 2',
        if (released) 'result': 'fail',
        if (released) 'verdict': 'fail',
        'is_pending': !released,
        'subjective_pending': 0,
        if (released) 'label': '1 / 2 - FAIL',
      },
      'rows': <Map<String, dynamic>>[
        <String, dynamic>{
          'index': 1,
          'question_id': 10,
          'name': 'End of Shift Parking Procedure',
          'prompt': 'Where must a forklift be parked at end of shift?',
          'question_type': 'mcq',
          'chosen': <String>['On the charging bay'],
          'correct': released ? <String>['On the charging bay'] : <String>[],
          'justification': '',
          'verdict': released ? 'Correct' : '',
          'kind': 'pass',
          'score_raw': null,
          'feedback': '',
          'score_verdict': '',
          'deductions': <String>[],
          'credit': <String>[],
        },
      ],
    };

/// `/api/v1/me/assessments` - her own list, carrying NO assessment record.
///
/// That absence is the precondition of the whole defect class this guards
/// against, so the fixture keeps it rather than quietly handing the screen a
/// record the real server never sends a candidate.
Map<String, dynamic> _meAssessmentsPayload({required bool released}) =>
    <String, dynamic>{
      'applicant': <String, dynamic>{'id': 2, 'name': 'Priya Sharma'},
      'buckets': <String, dynamic>{
        'available': <dynamic>[],
        'in_progress': <dynamic>[],
        'upcoming': <dynamic>[],
        'completed': <dynamic>[
          <String, dynamic>{
            'id': 4,
            'token': kToken,
            'assessment_id': 18,
            'name': kAssessmentName,
            'state': 'completed',
            'duration_minutes': 30,
            'submitted_at': '2026-08-05T07:58:23Z',
            'result': <String, dynamic>{
              'released': released,
              if (released) 'score_marks': '1 / 2',
              if (released) 'result': 'fail',
            },
            'can_review_answers': released,
          },
        ],
        'closed': <dynamic>[],
      },
      'total_count': 1,
    };

/// `/api/v1/exam/<token>/state` for a sitting she has already submitted.
///
/// REQUIRED, not scenery. A candidate never loads an Assessment record, so
/// this envelope is the only place her sitting's assessment comes from - the
/// runner's `initState` fetches it precisely because the record is missing.
/// Leaving it out of the stub makes the screen render the dead-link gate for a
/// reason the real server would never produce, which would be a test failing
/// on its own fixture rather than on the product.
Map<String, dynamic> _statePayload({required bool released}) =>
    <String, dynamic>{
      'outcome': 'complete',
      'assessment': <String, dynamic>{
        'id': 18,
        'name': kAssessmentName,
        'state': 'in_progress',
        'duration_minutes': 30,
      },
      'attempt': <String, dynamic>{
        'id': 4,
        'state': 'submitted',
        'is_locked': false,
        'started_at': '2026-08-05T07:30:00Z',
        'deadline': '2026-08-05T08:00:00Z',
        'submitted_at': '2026-08-05T07:58:23Z',
        'total_questions': 2,
        'answered_count': 2,
        'results_released': released,
      },
      'rules': <String, dynamic>{
        'tab_switch': false,
        'copy_paste': false,
        'right_click': false,
        'devtools': false,
        'fullscreen': false,
        'webcam': false,
        'watermark': false,
        'watermark_label': '',
        'max_violations': 3,
        'violation_action': 'log_only',
        'violation_count': 0,
      },
      'preview': false,
      'result': <String, dynamic>{
        'released': released,
        'status': released ? 'released' : 'awaiting_results',
        if (released) 'score_marks': '1 / 2',
        if (released) 'result': 'fail',
        if (released) 'verdict': 'fail',
        'is_pending': !released,
        'subjective_pending': 0,
        if (released) 'label': '1 / 2 - FAIL',
      },
    };

http.Client _candidateServer({required bool released}) =>
    MockClient((http.Request req) async {
      final String p = req.url.path;
      late final Map<String, dynamic> data;
      if (p.endsWith('/answers')) {
        data = _answersPayload(released: released);
      } else if (p.endsWith('/state')) {
        data = _statePayload(released: released);
      } else if (p.endsWith('/api/v1/me/assessments')) {
        data = _meAssessmentsPayload(released: released);
      } else {
        // Every manager route 403s for a candidate. Answering with an empty
        // object would make the test easier than reality.
        return http.Response(
          jsonEncode(<String, dynamic>{
            'ok': false,
            'error': <String, dynamic>{
              'code': 'forbidden',
              'message': 'You are not allowed to access this resource.',
            },
          }),
          403,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }
      return http.Response(
        jsonEncode(<String, dynamic>{'ok': true, 'data': data}),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    });

Future<AppStore> _candidateStore(
  WidgetTester t, {
  required bool released,
}) async {
  final AppStore s = AppStore(
    api: ApiClient(
      baseUrl: 'http://stub',
      client: _candidateServer(released: released),
      bearer: 'access_token_stub',
    ),
  );
  s.portal = Portal.member;
  s.source = DataSource.live;
  s.meId = '2';
  await t.runAsync(() => s.refresh());
  return s;
}

/// Mount the SECTION on My performance, the way the shell does.
Future<AssessmentNav> _openPerformance(
  WidgetTester t, {
  bool released = true,
}) async {
  // The grid declares a minWidth of 840, so the default 800x600 window would
  // overflow and the failure would read as a layout bug rather than a viewport
  // narrower than the app targets.
  t.view.physicalSize = const Size(1600, 1600);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);

  final AppStore s = await _candidateStore(t, released: released);
  addTearDown(s.dispose);

  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: AssessmentSection(
          store: s,
          entry: AssessmentEntry.myPerformance,
        ),
      ),
    ),
  );
  await t.pumpAndSettle();

  // Read from the scope element itself: the section BUILDS the scope, so its
  // own element sits above it and `of(context)` would find nothing.
  return t
      .widget<AssessmentNavScope>(find.byType(AssessmentNavScope))
      .notifier!;
}

Future<void> _settle(WidgetTester t) async {
  await t.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  await t.pumpAndSettle();
}

/// The sitting's name INSIDE the breakdown table.
///
/// Scoped to the grid on purpose: the same name also labels the "Best result"
/// KPI at the top of the page, and that tile is not a control. An unscoped
/// finder takes the KPI first, taps a piece of text that was never meant to
/// navigate, and reports "the row does not open" about a row it never touched.
Finder _breakdownRow() => find.descendant(
  of: find.byType(DataGrid),
  matching: find.text(kAssessmentName),
);

void main() {
  group('The Score breakdown row opens the sitting', () {
    testWidgets('a released row lands on the answer review', (
      WidgetTester t,
    ) async {
      final AssessmentNav nav = await _openPerformance(t);
      expect(_breakdownRow(), findsOneWidget);

      await t.tap(_breakdownRow());
      await _settle(t);

      expect(
        nav.current,
        isA<Exam>().having(
          (Exam e) => e.stage,
          'stage',
          ExamStage.answers,
        ),
        reason: 'the row must open her answers, not merely light up',
      );
      expect(
        find.text(kDeadLink),
        findsNothing,
        reason:
            'a candidate holds no Assessment record - gating the review on '
            'one is the defect this whole family of tests exists for',
      );
    });

    testWidgets('an unreleased row lands on its completion card, not a score', (
      WidgetTester t,
    ) async {
      // Same rule My assessments already applies. Nothing about the mark is
      // disclosed before an administrator releases it, so the destination is
      // the completion card rather than the answer sheet.
      final AssessmentNav nav = await _openPerformance(t, released: false);

      await t.tap(_breakdownRow());
      await _settle(t);

      expect(
        nav.current,
        isA<Exam>().having(
          (Exam e) => e.stage,
          'stage',
          ExamStage.complete,
        ),
      );
      expect(find.text(kDeadLink), findsNothing);
    });

    testWidgets('Back from the sitting returns to My Performance', (
      WidgetTester t,
    ) async {
      // THIS PINNED AN EMPTY TRAIL, which is what sent the candidate to the
      // wrong screen. She taps a score breakdown row on My Performance; the
      // only way out of the runner then landed her on My Assessments, a screen
      // she had not come from and had no reason to be on.
      //
      // The boundary is unchanged - the exam keeps ONE entry, the page it was
      // opened from, and nothing else. See `history_nav_test.dart`.
      final AssessmentNav nav = await _openPerformance(t);

      await t.tap(_breakdownRow());
      await _settle(t);
      expect(nav.current, isA<Exam>());

      expect(nav.canGoForward, isFalse, reason: 'nothing ahead of a sitting');
      expect(nav.canGoBack, isTrue);

      nav.back();
      await _settle(t);
      expect(nav.current, isA<MyPerformance>());
    });
  });
}
