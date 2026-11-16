// Every re-score button sends the answers it names, and only those.
//
// THE CASES (ETP_PLANS_AND_STRATEGY.md §3.8, "What the admin sees"): candidate Asha,
// Q7 scored 40/100, Q8 errored, Q2 an MCQ.
//
//   * Answer page, Q7 (scored): the button was hidden - it showed only on
//     unresolved answers - so a mark the admin doubted could not be re-graded.
//     Now it shows, sends Q7 alone, and reads "Re-score queued" until graded.
//   * Q2 (MCQ): no button. It is scored in code; the grader has nothing to do.
//   * Candidate page "Re-score 1 answer(s)": sends Q8, the one it counted.
//   * Responses, tick Asha Q7 + Q2 and Ben Q7, "Re-score 3 selected": it
//     re-scored each candidate's UNRESOLVED answers, not the ticked ones. Now
//     one request per candidate - Asha [Q7] (the MCQ dropped), Ben [Q7].
@TestOn('vm')
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/admin/attempt_detail_screen.dart';
import 'package:ethara_assessment/assessment/screens/admin/response_detail_screen.dart';
import 'package:ethara_assessment/assessment/screens/admin/responses_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/buttons.dart';
import 'package:ethara_assessment/assessment/widgets/feedback.dart';

/// Records every request; answers a route by exact path suffix, or `{}`.
class _Spy {
  final List<String> paths = <String>[];
  final List<Map<String, dynamic>> bodies = <Map<String, dynamic>>[];
  final Map<String, Map<String, dynamic>> canned =
      <String, Map<String, dynamic>>{};

  http.Client get client => MockClient((http.Request req) async {
    paths.add(req.url.path);
    try {
      bodies.add(jsonDecode(req.body) as Map<String, dynamic>);
    } on FormatException {
      bodies.add(<String, dynamic>{});
    }
    Map<String, dynamic> data = const <String, dynamic>{};
    for (final MapEntry<String, Map<String, dynamic>> e in canned.entries) {
      if (req.url.path.endsWith(e.key)) data = e.value;
    }
    return http.Response(
      jsonEncode(<String, dynamic>{'ok': true, 'data': data}),
      200,
      headers: <String, String>{'content-type': 'application/json'},
    );
  });

  /// The body of every rescore request, keyed by its attempt.
  Map<String, Map<String, dynamic>> get rescores =>
      <String, Map<String, dynamic>>{
        for (int i = 0; i < paths.length; i++)
          if (paths[i].endsWith('/rescore'))
            paths[i].split('/').reversed.elementAt(1): bodies[i],
      };
}

Map<String, dynamic> _answer(
  int qid, {
  required String state,
  required bool needsLlm,
  bool queued = false,
  int evaluator = 90,
  String type = 'subjective_rubric',
}) => <String, dynamic>{
  'id': evaluator * 1000 + qid,
  'evaluator_id': evaluator,
  'assessment_id': 7,
  'question_id': qid,
  'question_name': 'Q$qid',
  'question_type': type,
  'candidate': <String, dynamic>{
    'id': 'p$evaluator',
    'name': evaluator == 90 ? 'Asha' : 'Ben',
  },
  'state': 'submitted',
  'needs_llm': needsLlm,
  'has_objective': !needsLlm,
  'llm_state': state,
  'rescore_requested': queued,
  'justification': needsLlm ? 'The axes are mislabelled.' : '',
};

Assessment _paper() => Assessment.fromJson(<String, dynamic>{
  'id': '7',
  'name': 'Warehouse Safety',
  'state': 'in_progress',
  'questions': <dynamic>[
    <String, dynamic>{
      'id': 205,
      'name': 'Q205',
      'question_type': 'subjective_rubric',
    },
    <String, dynamic>{
      'id': 206,
      'name': 'Q206',
      'question_type': 'subjective_rubric',
    },
    <String, dynamic>{'id': 207, 'name': 'Q207', 'question_type': 'mcq'},
  ],
});

Map<String, dynamic> _ashaJson() => <String, dynamic>{
  'id': 90,
  'assessment_id': 7,
  'candidate': <String, dynamic>{'id': 'p90', 'name': 'Asha'},
  'state': 'submitted',
  'answers': <dynamic>[
    _answer(205, state: 'scored', needsLlm: true),
    _answer(206, state: 'error', needsLlm: true),
    _answer(207, state: 'not_needed', needsLlm: false, type: 'mcq'),
  ],
};

AppStore _live(_Spy spy) {
  final AppStore s = AppStore(
    api: ApiClient(baseUrl: 'http://stub', client: spy.client),
  );
  s.caps = Capability.values.toSet();
  s.people = <Person>[const Person(id: 'p90', name: 'Asha', email: 'a@x.io')];
  s.assessments = <Assessment>[_paper()];
  s.attempts = <Attempt>[Attempt.fromJson(_ashaJson())];
  return s;
}

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
  await t.pump();
  await t.pump();
}

/// Lets every toast expire, so no timer outlives the test.
Future<void> _drain(WidgetTester t) async {
  await t.pump(const Duration(seconds: 25));
  await t.pumpWidget(const SizedBox.shrink());
}

/// The answer page for Asha's [qid], served by the audit route as [answer].
Future<_Spy> _answerPage(
  WidgetTester t,
  int qid,
  Map<String, dynamic> answer,
) async {
  final _Spy spy = _Spy()
    ..canned['/responses/90/$qid'] = answer
    ..canned['/attempts/90/rescore'] = <String, dynamic>{'queued': 1};
  await _mount(
    t,
    ResponseDetailScreen(
      store: _live(spy),
      attemptId: '90',
      questionId: '$qid',
    ),
  );
  return spy;
}

Btn? _btn(WidgetTester t, String label) {
  final Finder f = find.widgetWithText(Btn, label);
  return f.evaluate().isEmpty ? null : t.widget<Btn>(f.first);
}

void main() {
  group('the answer page', () {
    testWidgets(
      'a SCORED answer offers Re-score, and it sends that answer alone',
      (WidgetTester t) async {
        final _Spy spy = await _answerPage(
          t,
          205,
          _answer(205, state: 'scored', needsLlm: true),
        );

        final Btn? btn = _btn(t, 'Re-score');
        expect(
          btn,
          isNotNull,
          reason: 'a mark the admin doubts is the commonest reason to re-grade',
        );
        expect(
          btn!.tooltip,
          'Grade this one answer again, on its own. One LLM call. The mark is '
          'replaced when the new grade succeeds; if it fails, the current mark '
          'stays.',
        );

        await t.tap(find.widgetWithText(Btn, 'Re-score'));
        await t.pump();

        expect(spy.rescores, <String, Map<String, dynamic>>{
          '90': <String, dynamic>{
            'question_ids': <int>[205],
          },
        });
        await _drain(t);
      },
    );

    testWidgets(
      'a queued answer reads "Re-score queued" and cannot be sent twice',
      (WidgetTester t) async {
        await _answerPage(
          t,
          205,
          _answer(205, state: 'scored', needsLlm: true, queued: true),
        );

        expect(_btn(t, 'Re-score'), isNull);
        final Btn? queued = _btn(t, 'Re-score queued');
        expect(queued, isNotNull);
        expect(
          queued!.onPressed,
          isNull,
          reason: 'a second click would only join the request already queued',
        );
        await _drain(t);
      },
    );

    testWidgets('an MCQ answer has no Re-score at all', (WidgetTester t) async {
      await _answerPage(
        t,
        207,
        _answer(207, state: 'not_needed', needsLlm: false, type: 'mcq'),
      );

      expect(
        _btn(t, 'Re-score'),
        isNull,
        reason: 'scored in code, nothing to grade',
      );
      expect(_btn(t, 'Re-score queued'), isNull);
      await _drain(t);
    });
  });

  testWidgets('the candidate page sends the unresolved answers it counted', (
    WidgetTester t,
  ) async {
    final _Spy spy = _Spy()..canned['/attempts/90'] = _ashaJson();
    await _mount(
      t,
      AttemptDetailScreen(
        store: _live(spy),
        portal: Portal.admin,
        attemptId: '90',
      ),
    );

    final Btn? btn = _btn(t, 'Re-score 1 answer(s)');
    expect(btn, isNotNull);
    expect(btn!.tooltip, contains('one LLM call grades up to 20 answers'));

    await t.tap(find.widgetWithText(Btn, 'Re-score 1 answer(s)'));
    await t.pump();

    expect(
      spy.rescores['90'],
      <String, dynamic>{
        'question_ids': <int>[206],
      },
      reason:
          'Q206 is the one unresolved answer; the scored Q205 and the MCQ '
          'are not in the count, so they are not in the request',
    );
    await _drain(t);
  });

  testWidgets('Responses: the ticked answers, one request per candidate', (
    WidgetTester t,
  ) async {
    final _Spy spy = _Spy()
      ..canned['/rescore'] = <String, dynamic>{'queued': 1};
    final AppStore s = _live(spy)
      ..responseRows = <Map<String, dynamic>>[
        _answer(205, state: 'scored', needsLlm: true),
        _answer(207, state: 'not_needed', needsLlm: false, type: 'mcq'),
        _answer(205, state: 'error', needsLlm: true, evaluator: 91),
      ];
    await _mount(t, ResponsesScreen(store: s));
    await t.pumpAndSettle();

    // Flat, so every row's tick box is on screen in arrival order.
    await t.tap(find.text('Assessment > Candidate').last);
    await t.pumpAndSettle();
    await t.tap(find.text('No grouping').last);
    await t.pumpAndSettle();

    final Finder ticks = find.byWidgetPredicate(
      (Widget w) => w.runtimeType.toString() == '_RowCheck',
    );
    expect(ticks, findsNWidgets(3));
    for (int i = 0; i < 3; i++) {
      await t.tap(ticks.at(i));
      await t.pump();
    }

    final Btn? btn = _btn(t, 'Re-score 3 selected');
    expect(btn?.tooltip, 'Grades exactly the ticked answers.');
    await t.tap(find.widgetWithText(Btn, 'Re-score 3 selected'));
    await t.pump();
    await t.pump();

    expect(
      spy.rescores,
      <String, Map<String, dynamic>>{
        '90': <String, dynamic>{
          'question_ids': <int>[205],
        },
        '91': <String, dynamic>{
          'question_ids': <int>[205],
        },
      },
      reason:
          'Asha\'s ticked MCQ is scored in code and is left out; each '
          'candidate gets one request naming only their ticked answers',
    );
    await t.pump();
    expect(
      s.toaster.items.map((ToastMsg m) => m.message),
      <String>['Queued 2 answer(s) for re-scoring across 2 candidate(s)'],
      reason: 'one press, one summary - not a toast per candidate',
    );
    await _drain(t);
  });
}
