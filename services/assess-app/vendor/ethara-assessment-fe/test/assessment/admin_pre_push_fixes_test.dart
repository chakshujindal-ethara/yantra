// Admin-screen fixes from the pre-push plan (ETP_PLANS_AND_STRATEGY.md §0.0,
// §0.2): S1/Q8, S5, S10, S11, Q18, N6, N9 and G1-23.
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
import 'package:ethara_assessment/assessment/screens/admin/assessment_detail_screen.dart';
import 'package:ethara_assessment/assessment/screens/admin/attempt_detail_screen.dart';
import 'package:ethara_assessment/assessment/screens/admin/bank_screen.dart';
import 'package:ethara_assessment/assessment/screens/admin/budget_screen.dart';
import 'package:ethara_assessment/assessment/screens/admin/dashboard_screen.dart';
import 'package:ethara_assessment/assessment/screens/admin/response_detail_screen.dart';
import 'package:ethara_assessment/assessment/screens/admin/settings_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/buttons.dart';
import 'package:ethara_assessment/assessment/widgets/feedback.dart';
import 'package:ethara_assessment/assessment/widgets/panel.dart';

/// Answers a route by path suffix: `data` on a 200, or a refusal when the
/// canned body carries `error`.
class _Spy {
  final Map<String, (int, Map<String, dynamic>)> canned =
      <String, (int, Map<String, dynamic>)>{};

  http.Client get client => MockClient((http.Request req) async {
    (int, Map<String, dynamic>) hit = (200, const <String, dynamic>{});
    for (final MapEntry<String, (int, Map<String, dynamic>)> e
        in canned.entries) {
      if (req.url.path.endsWith(e.key)) hit = e.value;
    }
    final Map<String, dynamic> body = hit.$1 == 200
        ? <String, dynamic>{'ok': true, 'data': hit.$2}
        : <String, dynamic>{'ok': false, ...hit.$2};
    return http.Response(
      jsonEncode(body),
      hit.$1,
      headers: <String, String>{'content-type': 'application/json'},
    );
  });

  void ok(String path, Map<String, dynamic> data) => canned[path] = (200, data);

  void refuse(String path, int status, String code, String message) =>
      canned[path] = (
        status,
        <String, dynamic>{
          'error': <String, dynamic>{'code': code, 'message': message},
        },
      );
}

AppStore _live(_Spy spy) => AppStore(
  api: ApiClient(baseUrl: 'http://stub', client: spy.client),
)..caps = Capability.values.toSet();

List<String> _toasts(AppStore s) =>
    s.toaster.items.map((ToastMsg m) => m.message).toList();

Btn? _btn(WidgetTester t, String label) {
  final Finder f = find.widgetWithText(Btn, label);
  return f.evaluate().isEmpty ? null : t.widget<Btn>(f.first);
}

Future<void> _mount(
  WidgetTester t,
  Widget child, {
  Size size = const Size(1800, 3000),
}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: AssessmentNavScope(nav: AssessmentNav(), child: child),
      ),
    ),
  );
  await t.pump();
  await t.pump();
  // Tearing the tree down cancels the screens' watch timers and toasts.
  addTearDown(() async {
    await t.pump(const Duration(seconds: 25));
    await t.pumpWidget(const SizedBox.shrink());
  });
}

// ── The assessment detail: one paper with a held error and work waiting ────

Assessment _paper({
  AsmState state = AsmState.inProgress,
  ScoringPhase? phase,
}) => Assessment(
  id: 'A-1',
  name: 'Warehouse Safety',
  state: state,
  scoringPhase: phase,
  awaitingScoringCount: 2,
);

AppStore _seeded(Assessment asm) => AppStore()
  ..assessments = <Assessment>[asm]
  ..attempts = <Attempt>[
    Attempt(
      id: '1',
      assessmentId: 'A-1',
      employeeId: 'P-1',
      token: 'tok',
      state: AttemptState.submitted,
      isLocked: true,
      subjectiveState: LlmState.error,
      subjectiveHasError: true,
    ),
  ];

Future<void> _detail(WidgetTester t, Assessment asm) => _mount(
  t,
  AssessmentDetailScreen(
    store: _seeded(asm),
    portal: Portal.admin,
    asmId: 'A-1',
    tab: 'config',
  ),
  size: const Size(1600, 2600),
);

// ── The candidate and answer pages (live, as the route sends them) ──────────

Map<String, dynamic> _wirePaper(String phase) => <String, dynamic>{
  'id': '7',
  'name': 'Warehouse Safety',
  'state': 'in_progress',
  'scoring_phase': phase,
  'questions': <dynamic>[
    <String, dynamic>{
      'id': 205,
      'name': 'Q205',
      'question_type': 'subjective_rubric',
    },
  ],
};

Map<String, dynamic> _answer(String state) => <String, dynamic>{
  'id': 90205,
  'evaluator_id': 90,
  'assessment_id': 7,
  'question_id': 205,
  'question_name': 'Q205',
  'question_type': 'subjective_rubric',
  'candidate': <String, dynamic>{'id': 'p90', 'name': 'Asha'},
  'state': 'submitted',
  'needs_llm': true,
  'llm_state': state,
  'justification': 'The axes are mislabelled.',
};

Map<String, dynamic> _asha(String answerState) => <String, dynamic>{
  'id': 90,
  'assessment_id': 7,
  'candidate': <String, dynamic>{'id': 'p90', 'name': 'Asha'},
  'state': 'submitted',
  'answers': <dynamic>[_answer(answerState)],
};

AppStore _liveAsha(_Spy spy, String phase, String answerState) => _live(spy)
  ..people = <Person>[const Person(id: 'p90', name: 'Asha', email: 'a@x.io')]
  ..assessments = <Assessment>[Assessment.fromJson(_wirePaper(phase))]
  ..attempts = <Attempt>[Attempt.fromJson(_asha(answerState))];

void main() {
  group('S1 / Q8: nothing is queued while a Kill is stopping', () {
    testWidgets('the detail screen disables Score All, Score Failed and '
        'Re-score This Assessment', (WidgetTester t) async {
      await _detail(t, _paper(phase: ScoringPhase.stopping));
      for (final String label in <String>[
        'Score All',
        'Score Failed Candidates (1)',
        'Re-score This Assessment',
      ]) {
        final Btn? b = _btn(t, label);
        expect(b, isNotNull, reason: label);
        expect(
          b!.onPressed,
          isNull,
          reason: '$label while stopping is parked straight back to cancelled',
        );
      }
    });

    testWidgets('the same buttons work while scoring', (WidgetTester t) async {
      await _detail(t, _paper(phase: ScoringPhase.scoring));
      for (final String label in <String>[
        'Score All',
        'Score Failed Candidates (1)',
        'Re-score This Assessment',
      ]) {
        expect(_btn(t, label)?.onPressed, isNotNull, reason: label);
      }
    });

    testWidgets('the candidate page disables its re-score', (
      WidgetTester t,
    ) async {
      final _Spy spy = _Spy()..ok('/attempts/90', _asha('error'));
      await _mount(
        t,
        AttemptDetailScreen(
          store: _liveAsha(spy, 'stopping', 'error'),
          portal: Portal.admin,
          attemptId: '90',
        ),
      );
      final Btn? b = _btn(t, 'Re-score 1 answer(s)');
      expect(b, isNotNull);
      expect(b!.onPressed, isNull);
    });

    testWidgets('the answer page disables Re-score', (WidgetTester t) async {
      final _Spy spy = _Spy()..ok('/responses/90/205', _answer('scored'));
      await _mount(
        t,
        ResponseDetailScreen(
          store: _liveAsha(spy, 'stopping', 'scored'),
          attemptId: '90',
          questionId: '205',
        ),
      );
      final Btn? b = _btn(t, 'Re-score');
      expect(b, isNotNull);
      expect(b!.onPressed, isNull);
    });

    const String why =
        'Scoring is still stopping on this assessment. Try again once the '
        'kill has settled.';

    test('a 409 stopping on Score All shows the server message', () async {
      final _Spy spy = _Spy()..refuse('/scoring/queue', 409, 'stopping', why);
      final AppStore s = _live(spy);
      await s.queueScoringFor(assessmentId: 'A-1');
      expect(_toasts(s), contains(why));
      expect(_toasts(s).any((String m) => m.startsWith('Queued')), isFalse);
    });

    test('a 409 stopping on a re-score shows the server message', () async {
      final _Spy spy = _Spy()
        ..refuse('/attempts/90/rescore', 409, 'stopping', why);
      final AppStore s = _live(spy);
      await s.rescoreAnswers(<String, List<String>?>{'90': null});
      expect(_toasts(s), contains(why));
    });
  });

  group('S5 / R7-01: no Re-score This Assessment on a cancelled paper', () {
    testWidgets('cancelled: the button is gone', (WidgetTester t) async {
      await _detail(t, _paper(state: AsmState.cancelled));
      expect(
        find.textContaining('held on a scoring error', findRichText: true),
        findsWidgets,
      );
      expect(_btn(t, 'Re-score This Assessment'), isNull);
    });

    testWidgets('done: the button stays', (WidgetTester t) async {
      await _detail(t, _paper(state: AsmState.done));
      expect(_btn(t, 'Re-score This Assessment'), isNotNull);
    });
  });

  testWidgets('S10: no Settings hint reads like a stored value', (
    WidgetTester t,
  ) async {
    t.view.physicalSize = const Size(1600, 4000);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: SettingsScreen(
            store: AppStore()
              ..settings = <String, dynamic>{
                'models': <String, dynamic>{'scoring': ''},
              },
          ),
        ),
      ),
    );
    await t.pumpAndSettle();

    String? hint(String label) => t
        .widget<TextField>(
          find.descendant(
            of: find
                .ancestor(
                  of: find.text(label.toUpperCase()),
                  matching: find.byType(Field),
                )
                .first,
            matching: find.byType(TextField),
          ),
        )
        .decoration
        ?.hintText;

    for (final String label in <String>[
      'Scoring model',
      'Fallback model',
      'Thinking level',
    ]) {
      expect(hint(label), isNull, reason: label);
    }
    expect(find.text('gemini-2.5-pro'), findsNothing);
  });

  testWidgets('S11: the bank Import tooltip says a native export goes live', (
    WidgetTester t,
  ) async {
    await _mount(
      t,
      BankScreen(store: AppStore()..caps = Capability.values.toSet()),
    );
    final String tip = _btn(t, 'Import')!.tooltip!;
    expect(tip, contains('CSV and harness JSON arrive as drafts'));
    expect(tip, contains('native bank export restores straight into the live'));
  });

  group('Q18 / F2-01: the Budget cards', () {
    LedgerRow row(int i) => LedgerRow(
      id: '$i',
      op: LedgerOp.scoreSubjective,
      model: 'gemini',
      tokensIn: 10,
      cost: 0.01,
      at: DateTime.utc(2026, 9, 1),
    );

    Kpi kpi(WidgetTester t, String label) => t.widget<Kpi>(
      find.byWidgetPredicate((Widget w) => w is Kpi && w.label == label),
    );

    testWidgets('read the lifetime totals the server sends', (
      WidgetTester t,
    ) async {
      final AppStore s = AppStore()
        ..ledger = List<LedgerRow>.generate(1000, row)
        ..budget = <String, dynamic>{
          'lifetime': <String, dynamic>{'spend_usd': 285.67, 'calls': 5268},
        };
      await _mount(t, BudgetScreen(store: s));

      expect(kpi(t, 'Total cost').value, r'$285.67');
      expect(kpi(t, 'Requests').value, '5,268');
      expect(kpi(t, 'Avg per request').value, r'$0.05');
      expect(
        kpi(t, 'Total tokens').sub,
        'last 1,000 calls',
        reason: 'what is still summed from the rows says it is a sample',
      );
    });

    testWidgets('say "last 1,000 calls" when lifetime is absent', (
      WidgetTester t,
    ) async {
      final AppStore s = AppStore()
        ..ledger = List<LedgerRow>.generate(1000, row);
      await _mount(t, BudgetScreen(store: s));

      expect(kpi(t, 'Total cost').value, r'$10.00');
      expect(kpi(t, 'Total cost').sub, 'last 1,000 calls');
      expect(kpi(t, 'Requests').sub, 'last 1,000 calls');
    });

    test('every backend ledger operation has its own label', () {
      // `llm_usage.operation` in assessments_be_v2/models/llm_usage.py.
      const List<String> backend = <String>[
        'extract_skills',
        'extract_tags',
        'generate_questions',
        'generate_image',
        'detect_image_elements',
        'locate_defect',
        'verify_planted_flaws',
        'generate_video',
        'submit_video_op',
        'fetch_video_op',
        'score_subjective',
        'scoring_cache_create',
        'scoring_cache_refresh',
        'assign_question_skills',
        'draft_task_template',
        'consolidate_vocab',
        'map_similarity',
      ];
      for (final String op in backend) {
        expect(LedgerOp.parse(op), isNot(LedgerOp.other), reason: op);
      }
      expect(LedgerOp.parse('draft_task_template').isAuthoring, isTrue);
      expect(LedgerOp.parse('scoring_cache_create').isAuthoring, isFalse);
    });
  });

  group('N6 / R1-05: the Kill toast counts candidates mid-call', () {
    Future<List<String>> kill(Map<String, dynamic> reply) async {
      final _Spy spy = _Spy()..ok('/kill_scoring', reply);
      final AppStore s = _live(spy);
      await s.killScoring('A-1');
      return _toasts(s);
    }

    test('held_count is named', () async {
      expect(
        await kill(<String, dynamic>{
          'settled_count': 0,
          'cleared_count': 0,
          'held_count': 2,
        }),
        contains(
          'Stopped grading; 2 being graded now will stop at their '
          'next call',
        ),
      );
    });

    test('without held_count the old sentence stays', () async {
      expect(
        await kill(<String, dynamic>{'settled_count': 0, 'cleared_count': 0}),
        contains('Nothing to stop - no candidate was being graded'),
      );
    });
  });

  testWidgets('N9 / F1-03: Starts shows the date, and Avg score fits', (
    WidgetTester t,
  ) async {
    final AppStore s = AppStore()
      ..assessments = <Assessment>[
        Assessment.fromJson(<String, dynamic>{
          'id': 'a1',
          'name': 'Alpha',
          'state': 'done',
          // 10:03 AM IST on 21 Sep.
          'start_date': '2026-09-21T04:33:00Z',
        }),
      ];
    // Two columns: the table's half (~647px) clears its 630px floor, so Avg
    // score fits without a sideways scroll. The pagination footer overflows at
    // this width under the test font; that is not what this checks.
    await _mount(t, DashboardScreen(store: s), size: const Size(1180, 3400));
    expect('${t.takeException()}', anyOf('null', contains('overflowed')));

    final Finder table = find.ancestor(
      of: find.text('Performance by Assessment'),
      matching: find.byType(Panel),
    );
    expect(
      find.descendant(of: table, matching: find.text('21/9/2026')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: table, matching: find.textContaining('IST')),
      findsNothing,
    );
    final Finder avg = find.descendant(
      of: table,
      matching: find.textContaining(RegExp('avg score', caseSensitive: false)),
    );
    expect(
      t.getRect(avg.first).right,
      lessThanOrEqualTo(t.getRect(table.first).right),
      reason: 'Avg score must not need a sideways scroll at laptop widths',
    );
  });

  group('G1-23: Release This Result on a candidate still being graded', () {
    Future<List<String>> release(Map<String, dynamic> reply) async {
      final _Spy spy = _Spy()..ok('/release', reply);
      final AppStore s = _live(spy)
        ..assessments = <Assessment>[
          Assessment(id: 'A-1', name: 'Paper', state: AsmState.done),
        ]
        ..attempts = <Attempt>[
          Attempt(
            id: '1',
            assessmentId: 'A-1',
            employeeId: 'P-1',
            token: 'tok',
            state: AttemptState.submitted,
            isLocked: true,
          ),
        ];
      await s.releaseOne('1');
      return _toasts(s);
    }

    test('0 released, 1 skipped: says it was not released', () async {
      final List<String> toasts = await release(<String, dynamic>{
        'released_count': 0,
        'skipped_count': 1,
      });
      expect(
        toasts,
        contains('Not released - this candidate is still being graded'),
      );
      expect(toasts, isNot(contains('Result released')));
    });

    test('1 released: still "Result released"', () async {
      expect(
        await release(<String, dynamic>{
          'released_count': 1,
          'skipped_count': 0,
        }),
        contains('Result released'),
      );
    });
  });
}
