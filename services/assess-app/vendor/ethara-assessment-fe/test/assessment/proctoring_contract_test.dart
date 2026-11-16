// Does the proctoring policy actually SURVIVE the wire?
//
// THE BUG THIS EXISTS FOR: `/api/v1/exam/<token>/state` sent the rule set as a
// top-level sibling of `assessment`, while `Assessment.fromJson` looks for it
// INSIDE the assessment object. Every one of the eight rules therefore parsed
// false, `ProctorRules.any` was false, and the exam runner returned before
// attaching a single browser listener. Proctoring was off for every candidate
// and nothing anywhere reported a problem: no error, no warning, a 200 on
// every call, and an operator UI that went on showing the rules as enabled.
//
// The key NAMES were right the whole time. Only the location was wrong, which
// is precisely the class of defect a type checker cannot see and a smoke test
// does not notice - so it is pinned here instead.
library;

import 'dart:convert';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// The rule block exactly as `serializers.proctoring_rules` builds it.
Map<String, dynamic> rulesBlock({
  bool tabSwitch = true,
  bool fullscreen = true,
  bool webcam = false,
  int maxViolations = 0,
  String violationAction = 'auto_submit',
}) => <String, dynamic>{
  'tab_switch': tabSwitch,
  'copy_paste': true,
  'right_click': true,
  'devtools': true,
  // DELIBERATELY STILL HERE. `screenshot` was removed as a rule, but the
  // frontend and the backend deploy separately, so a client will meet a server
  // that still sends this key. `RuleSet.fromJson` reads `ProctorRule.values`
  // and asks the payload for each one, so an extra key is ignored rather than
  // throwing - which is the property the test below pins.
  'screenshot': true,
  'fullscreen': fullscreen,
  'webcam': webcam,
  'watermark': true,
  'watermark_label': 'Ada Lovelace  ada@example.com',
  'max_violations': maxViolations,
  'violation_action': violationAction,
  'violation_count': 0,
};

/// The `assessment` sub-object of the exam-state envelope, post-fix: the rule
/// block is NESTED here, and the cap and the policy are hoisted alongside it.
Map<String, dynamic> examStateAssessment({
  Map<String, dynamic>? rules,
  int maxViolations = 0,
  String violationAction = 'auto_submit',
}) {
  final Map<String, dynamic> r =
      rules ??
      rulesBlock(
        maxViolations: maxViolations,
        violationAction: violationAction,
      );
  return <String, dynamic>{
    'id': 18,
    'name': 'L1 Screening',
    'state': 'in_progress',
    'duration_minutes': 45,
    'rules': r,
    'max_violations': r['max_violations'],
    'violation_action': r['violation_action'],
    'pass_threshold': 0.6,
  };
}

/// A live store holding one in-progress sitting, whose `/violation` route
/// answers with a chosen verdict.
///
/// The assessment is deliberately `log_only`: the client's own policy then
/// never ends the exam, so anything that does end it can only have come from
/// the server's response - which is the thing under test.
class _ViolationRig {
  _ViolationRig({required bool attemptEnded, required int count}) {
    store = AppStore(
      api: ApiClient(
        client: MockClient((http.Request req) async {
          final String path = req.url.path;
          Map<String, dynamic> data = <String, dynamic>{};
          if (path.endsWith('/violation')) {
            violationCalls++;
            data = <String, dynamic>{
              'recorded': true,
              'violation_count': count,
              'max_violations': count,
              'violation_action': 'auto_submit',
              'attempt_ended': attemptEnded,
            };
          } else if (path.endsWith('/submit')) {
            submitCalls++;
          }
          return http.Response(
            jsonEncode(<String, dynamic>{'ok': true, 'data': data}),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
        baseUrl: 'http://x',
      ),
    );
    store.assessments = <Assessment>[
      Assessment.fromJson(<String, dynamic>{
        'id': 18,
        'name': 'L1 Screening',
        'state': 'in_progress',
        'rules': rulesBlock(),
        'max_violations': 0,
        'violation_action': 'log_only',
      }),
    ];
    store.attempts = <Attempt>[
      Attempt.fromJson(<String, dynamic>{
        'id': 7,
        'assessment_id': 18,
        'access_token': 'tok',
        'state': 'in_progress',
      }),
    ];
  }

  late final AppStore store;
  int violationCalls = 0;
  int submitCalls = 0;

  /// True if the sitting was ever marked done, latched across the notifies.
  ///
  /// Latched rather than read at the end because `_endForViolation` kicks off
  /// a `refresh()`, and this rig's blank responses then empty the store.
  bool everEnded = false;
  void watch() {
    store.addListener(() {
      if (store.attemptById('7')?.isDone ?? false) everEnded = true;
    });
  }

  /// Let the unawaited report - and any submit it triggers - run to quiet.
  ///
  /// A fixed number of microtask turns rather than a timer: everything here is
  /// a resolved Future, and `pumpEventQueue` is not available outside a widget
  /// test.
  Future<void> settle() async {
    for (int i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// What `refresh()` and `loadExamByToken` both do to this attempt: throw the
  /// model away and rebuild it from the wire.
  ///
  /// `_loadCandidate` ends `attempts = flat;` - a wholesale replace - and
  /// `loadExamByToken` swaps the row outright. Neither can carry a violation
  /// timestamp, because no serializer sends one.
  void reparse({int violationCount = 1, String reason = ''}) {
    store.attempts = <Attempt>[
      Attempt.fromJson(<String, dynamic>{
        'id': 7,
        'assessment_id': 18,
        'access_token': 'tok',
        'state': 'in_progress',
        'proctoring': <String, dynamic>{
          'violation_count': violationCount,
          'violation_reason': reason,
        },
      }),
    ];
  }
}

void main() {
  group('the exam-state assessment carries its proctoring policy', () {
    test('every rule the server switched on arrives switched on', () {
      final Assessment a = Assessment.fromJson(examStateAssessment());

      // All seven, by name. A loop would pass just as happily against a
      // RuleSet that defaulted everything to true.
      expect(a.rules[ProctorRule.tabSwitch], isTrue);
      expect(a.rules[ProctorRule.copyPaste], isTrue);
      expect(a.rules[ProctorRule.rightClick], isTrue);
      expect(a.rules[ProctorRule.devtools], isTrue);
      expect(a.rules[ProctorRule.fullscreen], isTrue);
      expect(a.rules[ProctorRule.watermark], isTrue);
      expect(a.rules[ProctorRule.webcam], isFalse);
    });

    test('a rule the client no longer knows about is ignored', () {
      // The frontend and the backend ship separately, so a build without the
      // retired `screenshot` rule WILL be served payloads that still carry it.
      // `RuleSet.fromJson` walks the enum and asks the payload for each value,
      // so an unknown key falls out rather than throwing - and the seven rules
      // that remain must still parse correctly beside it.
      final Assessment a = Assessment.fromJson(examStateAssessment());

      expect(a.rules[ProctorRule.tabSwitch], isTrue);
      expect(
        ProctorRule.values.map((ProctorRule r) => r.wire),
        isNot(contains('screenshot')),
        reason: 'the rule was retired; a client must not resurrect it',
      );
    });

    test('the watermark label travels with the rules', () {
      // The runner used to derive this from the roster, which a candidate
      // never loads - so the one surface the watermark exists for painted
      // nothing while the instructions page listed the rule as active.
      final Assessment a = Assessment.fromJson(examStateAssessment());
      expect(a.watermarkLabel, 'Ada Lovelace  ada@example.com');
    });

    test('a rule the server switched OFF stays off', () {
      final Assessment a = Assessment.fromJson(
        examStateAssessment(rules: rulesBlock(tabSwitch: false)),
      );
      expect(a.rules[ProctorRule.tabSwitch], isFalse);
      // ...and its neighbours are untouched, so this is reading the rule and
      // not merely failing to find the block.
      expect(a.rules[ProctorRule.copyPaste], isTrue);
    });

    test('the cap and the policy are read, not defaulted', () {
      final Assessment a = Assessment.fromJson(
        examStateAssessment(maxViolations: 0, violationAction: 'auto_submit'),
      );
      // The module's own defaults, and the OPPOSITE of the client's fallback
      // (log-only, cap 3). While these were nested inside `rules` the client
      // could not see them, so an assessment set to end on the first violation
      // ran as one that never ends - and one set to log-only could have ended
      // a sitting the operator meant only to record.
      expect(a.maxViolations, 0);
      expect(a.violationAction, ViolationAction.autoSubmit);
    });

    test(
      'THE ORIGINAL BUG: rules beside the assessment leave every rule off',
      () {
        // The pre-fix envelope shape. Kept as a test rather than deleted,
        // because "the rules are somewhere in the payload" is exactly the
        // reasoning that shipped the bug - they have to be in the object the
        // parser is handed.
        final Map<String, dynamic> beside = examStateAssessment()
          ..remove('rules');
        final Assessment a = Assessment.fromJson(beside);
        expect(
          a.rules.enabled,
          isEmpty,
          reason: 'a sibling rule block is invisible to Assessment.fromJson',
        );
      },
    );
  });

  group('rules are written under the field names the module allow-lists', () {
    test('every rule maps to a distinct rule_* field', () {
      final Set<String> fields = ProctorRule.values
          .map((ProctorRule r) => r.field)
          .toSet();
      expect(fields.length, ProctorRule.values.length);
      for (final ProctorRule r in ProctorRule.values) {
        expect(r.field, startsWith('rule_'));
      }
    });

    test('the write name is NOT the read name', () {
      // The module reports rules under the short spelling and accepts them
      // only under the long one. `createAssessment` keyed its body by the
      // short spelling, so `ASSESSMENT_FIELDS` dropped all eight and the route
      // still answered 200: the operator configured proctoring and silently
      // got the defaults. Update always used the long names, which is why
      // editing an assessment worked and creating one did not.
      expect(ProctorRule.tabSwitch.wire, 'tab_switch');
      expect(ProctorRule.tabSwitch.field, 'rule_block_tab_switch');
      expect(ProctorRule.fullscreen.wire, 'fullscreen');
      expect(ProctorRule.fullscreen.field, 'rule_fullscreen');
    });

    test('create sends the long names on the wire', () async {
      Map<String, dynamic>? sent;
      final ApiClient api = ApiClient(
        client: MockClient((http.Request req) async {
          if (req.url.path.endsWith('/assessments/create')) {
            sent = jsonDecode(req.body) as Map<String, dynamic>;
          }
          return http.Response(
            jsonEncode(<String, dynamic>{
              'ok': true,
              'data': <String, dynamic>{},
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
        baseUrl: 'http://x',
      );

      await api.createAssessment(
        name: 'L1 Screening',
        rules: const RuleSet(<ProctorRule, bool>{
          ProctorRule.tabSwitch: true,
          ProctorRule.webcam: true,
        }).asMap,
      );

      expect(sent, isNotNull);
      expect(sent!['rule_block_tab_switch'], isTrue);
      expect(sent!['rule_webcam'], isTrue);
      // The short spellings must NOT be on the body: the server ignores them,
      // so their presence is the bug rather than harmless duplication.
      expect(sent!.containsKey('tab_switch'), isFalse);
      expect(sent!.containsKey('webcam'), isFalse);
    });
  });

  group('the violation tally comes from the server', () {
    test("a candidate's own attempt row is read out of `proctoring`", () {
      // `serializers.attempt` groups these under `proctoring`; the parser knew
      // `flags` and the flat spelling and neither matched, so the one surface
      // a candidate actually loads reported zero violations however many the
      // server had recorded.
      final Attempt ev = Attempt.fromJson(<String, dynamic>{
        'id': 7,
        'assessment_id': 18,
        'proctoring': <String, dynamic>{
          'is_violated': true,
          'violation_count': 2,
          'violation_reason': 'Tab switched / window hidden',
        },
      });
      expect(ev.violationCount, 2);
      expect(ev.violationReason, 'Tab switched / window hidden');
    });

    test('the exam-state attempt block is read too', () {
      final Attempt ev = Attempt.fromJson(<String, dynamic>{
        'id': 7,
        'assessment_id': 18,
        'violation_count': 3,
        'violation_reason': 'Exited fullscreen',
      });
      expect(ev.violationCount, 3);
    });

    test("the server's tally replaces the optimistic local one", () async {
      final _ViolationRig rig = _ViolationRig(attemptEnded: false, count: 5);
      final bool ended = rig.store.recordViolation('7', 'Tab switched');

      expect(ended, isFalse, reason: 'log_only never ends it locally');
      // The optimistic bump lands first, so the sitting is never momentarily
      // un-counted while the report is in flight.
      expect(rig.store.attemptById('7')!.violationCount, 1);

      await rig.settle();

      expect(rig.violationCalls, 1, reason: 'reported exactly once');
      expect(
        rig.store.attemptById('7')!.violationCount,
        5,
        reason:
            'the local count restarts at zero on every reload, so the '
            "server's is the only one that can enforce a cap",
      );
    });

    test('the same reason twice in a second counts once', () async {
      // The module refuses a repeat of the same reason inside 1.2s. Without a
      // matching filter the client counted an event the server discarded,
      // reached the cap first, and auto-submitted a sitting whose
      // authoritative count was still below its own threshold - two Ctrl+C
      // presses did it at a cap of 2.
      final _ViolationRig rig = _ViolationRig(attemptEnded: false, count: 1);
      expect(rig.store.recordViolation('7', 'Clipboard action: copy'), isFalse);
      expect(rig.store.recordViolation('7', 'Clipboard action: copy'), isFalse);

      expect(rig.store.attemptById('7')!.violationCount, 1);
      await rig.settle();
      expect(rig.violationCalls, 1, reason: 'the second is never even sent');
    });

    test('a refresh cannot disarm the dedup', () async {
      // THE BUG THIS EXISTS FOR: the guard read `violationAt` off the Attempt,
      // and the Attempt is rebuilt from the wire on every refresh. The API
      // sends NO violation timestamp at all - `serializers.attempt` sends the
      // count and the reason, and `violation_datetime` is written by
      // `_record_violation` but never serialised - so the field came back null
      // and the dedup stopped folding for the rest of the sitting. Every other
      // dedup test here records its burst against one unrefreshed model, which
      // is the single condition under which the old guard worked.
      final _ViolationRig rig = _ViolationRig(attemptEnded: false, count: 1);
      rig.store.recordViolation('7', 'Clipboard action: copy');
      await rig.settle();

      rig.reparse(violationCount: 1, reason: 'Clipboard action: copy');
      expect(
        rig.store.attemptById('7')!.violationAt,
        isNull,
        reason: 'the precondition: the wire carries no violation timestamp',
      );

      expect(rig.store.recordViolation('7', 'Clipboard action: copy'), isFalse);
      await rig.settle();

      // The load-bearing assertion is the CALL COUNT, not the tally: this
      // rig's server answers 1 both times, so a count assertion alone would
      // pass while the client was double-reporting.
      expect(
        rig.violationCalls,
        1,
        reason: 'one physical action is one violation, refresh or no refresh',
      );
    });

    test(
      'only the LAST reason is deduped, exactly as the server does',
      () async {
        // `_record_violation` compares against the ONE stored
        // reason/datetime pair, so A-B-A inside 1.2s is three violations there.
        // A per-reason map here would fold the third and leave this client BELOW
        // the server's tally - the mirror of the bug the dedup was written to
        // prevent, and the worse one, because a client that under-counts never
        // trips its own cap and nothing looks wrong.
        final _ViolationRig rig = _ViolationRig(attemptEnded: false, count: 3);
        rig.store.recordViolation('7', 'Clipboard action: copy');
        rig.store.recordViolation('7', 'Right-click attempted');
        rig.store.recordViolation('7', 'Clipboard action: copy');
        await rig.settle();

        expect(rig.violationCalls, 3);
      },
    );

    test('a DIFFERENT reason in the same second still counts', () {
      final _ViolationRig rig = _ViolationRig(attemptEnded: false, count: 9);
      rig.store.recordViolation('7', 'Clipboard action: copy');
      rig.store.recordViolation('7', 'Right-click attempted');
      expect(rig.store.attemptById('7')!.violationCount, 2);
    });

    test('a finished sitting cannot be violated', () async {
      final _ViolationRig rig = _ViolationRig(attemptEnded: false, count: 9);
      rig.store.attempts = <Attempt>[
        Attempt.fromJson(<String, dynamic>{
          'id': 7,
          'assessment_id': 18,
          'access_token': 'tok',
          'state': 'submitted',
          'is_locked': true,
        }),
      ];

      // A listener that outlived the exam - the watcher used to survive onto
      // the completion screen - re-entered finishExam on a submitted attempt
      // and re-POSTed the entire submission on every further right-click.
      expect(rig.store.recordViolation('7', 'Right-click attempted'), isFalse);
      await rig.settle();

      expect(rig.violationCalls, 0);
      expect(rig.submitCalls, 0);
      expect(rig.store.attemptById('7')!.violationCount, 0);
    });

    test('attempt_ended from the server ends the sitting', () async {
      // The LOCAL policy here is log-only, which never ends an exam. The
      // server's is not, and the server is the authority - this is exactly
      // the disagreement the client used to be unable to see, because the
      // response was discarded by a swallowing catchError.
      final _ViolationRig rig = _ViolationRig(attemptEnded: true, count: 5);
      rig.watch();
      expect(rig.store.recordViolation('7', 'Tab switched'), isFalse);

      await rig.settle();

      expect(rig.everEnded, isTrue, reason: 'the sitting is marked done');
      // AND WITHOUT POSTING /submit. The module refuses a submit while
      // questions are unanswered unless the clock ran out, so a violation
      // auto-submit - which lands on a half-finished paper by definition -
      // was refused, and the candidate saw "Assessment submitted" and "Your
      // exam was NOT submitted" side by side on a sitting the server had in
      // fact already ended correctly. The server auto-submits it itself.
      expect(
        rig.submitCalls,
        0,
        reason:
            'the server already ended it; a second /submit is refused '
            'for the unanswered questions it deliberately left blank',
      );
    });
  });

  group('the full per-reason violation tally parses onto the attempt', () {
    test('an ordered list of {reason, count} is read as sent', () {
      final Attempt ev = Attempt.fromJson(<String, dynamic>{
        'id': 7,
        'assessment_id': 18,
        'violation_count': 6,
        'violations': <Map<String, dynamic>>[
          <String, dynamic>{'reason': 'Right-click attempted', 'count': 3},
          <String, dynamic>{'reason': 'Tab switched/window hidden', 'count': 2},
          <String, dynamic>{'reason': 'Clipboard action: copy', 'count': 1},
        ],
      });
      expect(ev.violations.length, 3);
      // Order preserved, not re-sorted.
      expect(ev.violations.first.reason, 'Right-click attempted');
      expect(ev.violations.first.count, 3);
      expect(ev.violations.last.count, 1);
    });

    test('a legacy attempt with no violations key parses to an empty tally', () {
      final Attempt ev = Attempt.fromJson(<String, dynamic>{
        'id': 7,
        'assessment_id': 18,
        'violation_count': 2,
        'violation_reason': 'Exited fullscreen',
      });
      expect(ev.violations, isEmpty);
      // The count and last-reason still read, so the fallback line has what it
      // needs.
      expect(ev.violationCount, 2);
      expect(ev.violationReason, 'Exited fullscreen');
    });

    test('a malformed tally is tolerated, not fatal', () {
      // Free-form rows have arrived with a missing count or a non-map entry;
      // none may throw and lose the whole attempt on parse.
      final Attempt ev = Attempt.fromJson(<String, dynamic>{
        'id': 7,
        'assessment_id': 18,
        'violations': <dynamic>[
          'not-a-map',
          <String, dynamic>{'reason': 'Right-click attempted'}, // no count
          <String, dynamic>{'count': 4}, // no reason
        ],
      });
      // The bare string and the reason-less entry are skipped; the count-less
      // one keeps its reason with a count of 0.
      expect(ev.violations.length, 1);
      expect(ev.violations.first.reason, 'Right-click attempted');
      expect(ev.violations.first.count, 0);
    });

    test('the tally survives a JSON round-trip', () {
      final Attempt ev = Attempt.fromJson(<String, dynamic>{
        'id': 7,
        'assessment_id': 18,
        'violations': <Map<String, dynamic>>[
          <String, dynamic>{'reason': 'Right-click attempted', 'count': 3},
        ],
      });
      final Attempt back = Attempt.fromJson(ev.toJson());
      expect(back.violations.length, 1);
      expect(back.violations.first.reason, 'Right-click attempted');
      expect(back.violations.first.count, 3);
    });
  });

  test('the cap reached here waits for the server before re-reading', () async {
    // Seen in the browser: the local end re-read the sitting in the same
    // millisecond as the /violation POST, the re-read won with the sitting
    // still `in_progress`, and the candidate was put back on a live exam
    // whose every answer the server then refused.
    final List<String> log = <String>[];
    final AppStore store = AppStore(
      api: ApiClient(
        client: MockClient((http.Request req) async {
          Map<String, dynamic> data = <String, dynamic>{};
          if (req.url.path.endsWith('/violation')) {
            log.add('violation sent');
            await Future<void>.delayed(const Duration(milliseconds: 20));
            log.add('violation answered');
            data = <String, dynamic>{
              'recorded': true,
              'violation_count': 1,
              'attempt_ended': true,
            };
          } else {
            log.add('re-read');
          }
          return http.Response(
            jsonEncode(<String, dynamic>{'ok': true, 'data': data}),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
        baseUrl: 'http://x',
      ),
    );
    store.assessments = <Assessment>[
      Assessment.fromJson(<String, dynamic>{
        'id': 18,
        'name': 'L1 Screening',
        'state': 'in_progress',
        'rules': rulesBlock(maxViolations: 1),
        'max_violations': 1,
        'violation_action': 'auto_submit',
      }),
    ];
    store.attempts = <Attempt>[
      Attempt.fromJson(<String, dynamic>{
        'id': 7,
        'assessment_id': 18,
        'access_token': 'tok',
        'state': 'in_progress',
      }),
    ];

    // Not ended here at all any more (BR-D1): the reply's `attempt_ended` ends
    // it, so nothing can be shown as submitted that the server did not end.
    bool ended = false;
    store.addListener(() => ended |= store.attemptById('7')?.isDone ?? false);
    expect(store.recordViolation('7', 'Exited fullscreen'), isFalse);
    expect(store.attemptById('7')!.isDone, isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 60));

    expect(ended, isTrue, reason: 'the reply ended it');
    expect(log.first, 'violation sent');
    expect(log, contains('re-read'), reason: 'the server copy is re-read');
    expect(
      log.indexOf('re-read'),
      greaterThan(log.indexOf('violation answered')),
      reason: 'a re-read sent before the reply raced it: $log',
    );
  });
}
