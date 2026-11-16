// R5: AI proctoring violations ("AI: " reasons) count apart from the regular
// ones, each kind against its own cap and its own action. A paper can log the
// regular ones only and still end on the AI ones, or the other way round.
library;

import 'dart:async';
import 'dart:convert';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const String _ai = 'AI: phone detected';

void main() {
  group('the paper and the attempt carry both kinds', () {
    test('a paper without the AI pair reads the regular one', () {
      final Assessment a = Assessment.fromJson(<String, dynamic>{
        'id': 18,
        'max_violations': 4,
        'violation_action': 'auto_submit',
      });
      expect(a.policy(true), (action: ViolationAction.autoSubmit, cap: 4));
      expect(a.policy(false), (action: ViolationAction.autoSubmit, cap: 4));
    });

    test('a paper with it keeps them apart', () {
      final Assessment a = Assessment.fromJson(<String, dynamic>{
        'id': 18,
        'max_violations': 4,
        'violation_action': 'log_only',
        'ai_max_violations': 1,
        'ai_violation_action': 'auto_submit',
      });
      expect(a.policy(false), (action: ViolationAction.logOnly, cap: 4));
      expect(a.policy(true), (action: ViolationAction.autoSubmit, cap: 1));
      expect(a.aiViolationLimit, 1);
      expect(Assessment.fromJson(a.toJson()).policy(true), a.policy(true));
    });

    test('a roster row parses the AI count and its status', () {
      final Attempt ev = Attempt.fromJson(<String, dynamic>{
        'id': 7,
        'assessment_id': 18,
        'flags': <String, dynamic>{
          'violation_count': 2,
          'ai_violation_count': 3,
          'ai_violation_limit_breached': true,
          'ai_violations': <dynamic>[
            <String, dynamic>{'reason': _ai, 'count': 3},
          ],
          'ai_status': 'failed',
        },
      });
      expect(ev.countOf(false), 2);
      expect(ev.countOf(true), 3);
      expect(ev.aiViolationLimitBreached, isTrue);
      expect(ev.aiViolations, <({String reason, int count})>[
        (reason: _ai, count: 3),
      ]);
      expect(ev.aiStatus, 'failed');
      // Carried by a local change, not dropped.
      final Attempt moved = ev.copyWith(violationCount: 5);
      expect(moved.aiViolationCount, 3);
      expect(moved.aiStatus, 'failed');
    });

    test('the AI limit is the AI cap, not the regular one', () {
      final Assessment a = Assessment.fromJson(<String, dynamic>{
        'id': 18,
        'max_violations': 9,
        'ai_max_violations': 2,
        'ai_violation_action': 'log_only',
      });
      const Attempt ev = Attempt(
        id: '7',
        assessmentId: '18',
        employeeId: '1',
        token: 'tok',
        violationCount: 2,
        aiViolationCount: 2,
      );
      expect(ev.aiLimitBreached(a), isTrue);
      expect(ev.limitBreached(a), isFalse);
    });

    test('only the AI prefix is an AI reason', () {
      expect(isAiReason('AI: no face for 5s'), isTrue);
      expect(isAiReason('Tab switched / window hidden'), isFalse);
      expect(isAiReason('AIr conditioning'), isFalse);
    });
  });

  group('the store counts each kind against its own pair', () {
    test('an AI reason moves the AI count only', () async {
      final _Rig rig = _Rig();
      rig.store.recordViolation('7', _ai);
      final Attempt ev = rig.store.attemptById('7')!;
      expect(ev.aiViolationCount, 1);
      expect(
        ev.violationCount,
        0,
        reason: 'the regular count is the other kind',
      );
      await rig.settle();
    });

    test(
      'AI cap 1 under Auto locks; the regular log-only kind does not',
      () async {
        final _Rig rig = _Rig(hold: true);
        rig.store.recordViolation('7', 'Tab switched / window hidden');
        rig.store.recordViolation('7', 'Exited fullscreen');
        rig.store.recordViolation('7', 'Right-click attempted');
        expect(
          rig.store.violationLocked('tok'),
          isFalse,
          reason: 'three regular ones under Log only, cap 1: never ends',
        );
        rig.store.recordViolation('7', _ai);
        expect(rig.store.violationLocked('tok'), isTrue);
        rig.release();
        await rig.settle();
      },
    );

    test('a regular report does not lock on a high AI count', () async {
      final _Rig rig = _Rig(hold: true, regularAuto: true, regularCap: 5);
      rig.store.attempts = <Attempt>[
        rig.store.attemptById('7')!.copyWith(aiViolationCount: 9),
      ];
      rig.store.recordViolation('7', 'Exited fullscreen');
      expect(rig.store.violationLocked('tok'), isFalse);
      rig.release();
      await rig.settle();
    });

    test('the server ending it on an AI report stamps ai_violation', () async {
      final _Rig rig = _Rig(serverEnds: true);
      String? endedWith;
      rig.store.addListener(() {
        final Attempt? a = rig.store.attemptById('7');
        if (a?.isDone ?? false) endedWith ??= a!.autoSubmitReason;
      });
      rig.store.recordViolation('7', _ai);
      await rig.settle();
      expect(endedWith, 'ai_violation');
    });

    test('an AI limit the server says is breached is marked', () async {
      final _Rig rig = _Rig(servedAi: 1, aiBreached: true);
      rig.store.recordViolation('7', _ai);
      await rig.settle();
      final Attempt ev = rig.store.attemptById('7')!;
      expect(ev.aiViolationLimitBreached, isTrue);
      expect(ev.violationLimitBreached, isFalse, reason: 'the other kind');
    });

    // N1, per kind: the report that would have ended the sitting is refused,
    // the server says it is still open, and each count is taken from it.
    test(
      'a sitting still open after a refused ending takes each count',
      () async {
        final _Rig rig = _Rig(
          refuse: true,
          state: <String, dynamic>{
            'outcome': 'question',
            'attempt': <String, dynamic>{
              'violation_count': 3,
              'ai_violation_count': 0,
            },
          },
        );
        rig.store.recordViolation('7', _ai);
        expect(rig.store.violationLocked('tok'), isTrue, reason: 'AI cap 1');
        await rig.settle();
        final Attempt ev = rig.store.attemptById('7')!;
        expect(ev.isDone, isFalse);
        expect(ev.violationCount, 3);
        expect(ev.aiViolationCount, 0);
        expect(rig.store.violationLocked('tok'), isFalse);
      },
    );

    test('each report carries its own stamp, in epoch ms', () async {
      final _Rig rig = _Rig();
      final int before = DateTime.now().millisecondsSinceEpoch;
      rig.store.recordViolation('7', 'Exited fullscreen');
      await rig.settle();
      expect(rig.bodies, hasLength(1));
      final Object? at = rig.bodies.single['at'];
      expect(at, isA<int>());
      expect(at! as int, greaterThanOrEqualTo(before));
      expect(rig.bodies.single['reason'], 'Exited fullscreen');
    });

    test('the server reply corrects each count apart', () async {
      final _Rig rig = _Rig(servedAi: 4, served: 1);
      rig.store.recordViolation('7', _ai);
      await rig.settle();
      final Attempt ev = rig.store.attemptById('7')!;
      expect(ev.aiViolationCount, 4);
      expect(ev.violationCount, 1);
    });
  });
}

/// One live in-progress sitting: regular violations Log only, cap 1; AI ones
/// Auto-submit, cap 1. [hold] keeps every `/violation` unanswered until
/// [release], so the reports stay queued. [serverEnds] answers
/// `attempt_ended: true`.
class _Rig {
  _Rig({
    bool hold = false,
    bool serverEnds = false,
    bool regularAuto = false,
    int regularCap = 1,
    int? served,
    int? servedAi,
    bool aiBreached = false,
    bool refuse = false,
    Map<String, dynamic>? state,
  }) {
    if (!hold) _gate.complete();
    store = AppStore(
      api: ApiClient(
        maxAttempts: 1,
        client: MockClient((http.Request req) async {
          final bool violation = req.url.path.endsWith('/violation');
          if (violation) {
            bodies.add(jsonDecode(req.body) as Map<String, dynamic>);
            await _gate.future;
          }
          if (violation && refuse) {
            return http.Response(
              jsonEncode(<String, dynamic>{
                'ok': false,
                'error': <String, dynamic>{
                  'code': 'server_error',
                  'message': 'Ending the attempt failed.',
                },
              }),
              500,
              headers: <String, String>{'content-type': 'application/json'},
            );
          }
          final Map<String, dynamic> data = violation
              ? <String, dynamic>{
                  'recorded': true,
                  'attempt_ended': serverEnds,
                  'violation_count': ?served,
                  'ai_violation_count': ?servedAi,
                  if (aiBreached) 'ai_violation_limit_breached': true,
                }
              : req.url.path.endsWith('/state')
              ? (state ?? <String, dynamic>{})
              : <String, dynamic>{};
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
        'max_violations': regularCap,
        'violation_action': regularAuto ? 'auto_submit' : 'log_only',
        'ai_max_violations': 1,
        'ai_violation_action': 'auto_submit',
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

  final Completer<void> _gate = Completer<void>();
  final List<Map<String, dynamic>> bodies = <Map<String, dynamic>>[];
  late final AppStore store;

  void release() {
    if (!_gate.isCompleted) _gate.complete();
  }

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 50));
}
