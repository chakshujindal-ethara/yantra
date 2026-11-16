// A refused Configuration save puts the server's value back on screen.
//
// `updateAsm` shows an edit at once and never undid it. The re-read after a
// refusal is the LIST, whose rows lack the detail-only fields (the AI pair,
// "show answers", the transcription bar), so the merge kept the refused value
// and the tab went on showing a setting the server never took.
//
// Only the refused edit comes off. Putting back the whole record as it stood
// at the call also erased a second edit made while the first was on the wire,
// and the refresh after that second save kept the erased value on screen.
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

const Map<String, dynamic> _detail = <String, dynamic>{
  'id': 7,
  'name': 'Hindi clips',
  'state': 'in_progress',
  'duration_minutes': 45,
  'ai_violation_action': 'log_only',
  'ai_max_violations': 5,
  'results_show_answers': true,
  'transcription_threshold': 0.0,
};

http.Response _reply(Object body, int status) => http.Response(
  jsonEncode(body),
  status,
  headers: <String, String>{'content-type': 'application/json'},
);

AppStore _store() {
  final AppStore s = AppStore(
    api: ApiClient(
      baseUrl: 'http://x',
      client: MockClient((http.Request req) async {
        final String p = req.url.path;
        if (p.endsWith('/update')) {
          return _reply(<String, dynamic>{
            'ok': false,
            'error': <String, dynamic>{
              'code': 'invalid',
              'message': 'Not while candidates are sitting it.',
            },
          }, 409);
        }
        if (p.endsWith('/assessments/7')) {
          return _reply(<String, dynamic>{'ok': true, 'data': _detail}, 200);
        }
        if (p.endsWith('/assessments')) {
          // A list row: none of the detail-only keys.
          return _reply(<String, dynamic>{
            'ok': true,
            'data': <dynamic>[
              <String, dynamic>{'id': 7, 'name': 'Hindi clips'},
            ],
            'meta': <String, dynamic>{'total': 1},
          }, 200);
        }
        return _reply(<String, dynamic>{'ok': true, 'data': <dynamic>[]}, 200);
      }),
    ),
  );
  addTearDown(s.dispose);
  return s;
}

void main() {
  test('a refused save leaves the detail-only settings as stored', () async {
    final AppStore s = _store();
    await s.loadAssessment('7');
    final Assessment held = s.asmById('7')!;

    await s.updateAsm(
      held.copyWith(
        aiViolationAction: ViolationAction.autoSubmit,
        aiMaxViolations: 2,
        durationMinutes: 90,
        transcriptionThreshold: 85,
      ),
    );

    final Assessment now = s.asmById('7')!;
    expect(now.aiViolationAction, ViolationAction.logOnly);
    expect(now.aiMaxViolations, 5);
    expect(now.durationMinutes, 45);
    expect(now.transcriptionThreshold, 0);
  });
  // THE UNDO ITSELF, not the re-read after it: the detail is unreachable
  // after the first load, so only the rollback can put the switch back.
  test('a refused save puts the answers switch back, even when the re-read '
      'fails', () async {
    int reads = 0;
    final AppStore s = AppStore(
      api: ApiClient(
        baseUrl: 'http://x',
        client: MockClient((http.Request req) async {
          final String p = req.url.path;
          if (p.endsWith('/update')) {
            return _reply(<String, dynamic>{
              'ok': false,
              'error': <String, dynamic>{
                'code': 'invalid',
                'message': 'Not while candidates are sitting it.',
              },
            }, 409);
          }
          if (p.endsWith('/assessments/7')) {
            return reads++ == 0
                ? _reply(<String, dynamic>{'ok': true, 'data': _detail}, 200)
                : _reply(<String, dynamic>{'ok': false}, 503);
          }
          if (p.endsWith('/assessments')) {
            // A list row: none of the detail-only keys.
            return _reply(<String, dynamic>{
              'ok': true,
              'data': <dynamic>[
                <String, dynamic>{'id': 7, 'name': 'Hindi clips'},
              ],
              'meta': <String, dynamic>{'total': 1},
            }, 200);
          }
          return _reply(<String, dynamic>{
            'ok': true,
            'data': <dynamic>[],
          }, 200);
        }),
      ),
    );
    addTearDown(s.dispose);
    await s.loadAssessment('7');

    await s.updateAsm(
      s
          .asmById('7')!
          .copyWith(resultsShowAnswers: false, transcriptionThreshold: 85),
    );

    expect(reads, greaterThan(1), reason: 'the re-read was tried and failed');
    expect(s.asmById('7')!.resultsShowAnswers, isTrue);
    expect(s.asmById('7')!.transcriptionThreshold, 0, reason: 'R7 too');
  });

  group('two saves on the wire at once', () {
    test('a refused save takes back its own field, not a later edit', () async {
      final _Held server = _Held();
      final AppStore s = server.store();
      await s.loadAssessment('7');

      // Enter on the AI cap, then the AI action before the first reply.
      final Future<void> first = s.updateAsm(
        s.asmById('7')!.copyWith(aiMaxViolations: 2),
      );
      final Future<void> second = s.updateAsm(
        s.asmById('7')!.copyWith(aiViolationAction: ViolationAction.autoSubmit),
      );
      await pumpEventQueue();
      expect(server.gates, hasLength(2));

      server.gates[0].complete(false);
      await first;
      server.gates[1].complete(true);
      await second;

      final Assessment now = s.asmById('7')!;
      expect(now.aiMaxViolations, 5, reason: 'the refused cap is undone');
      expect(
        now.aiViolationAction,
        ViolationAction.autoSubmit,
        reason: 'the server took it',
      );
      expect(server.stored['ai_violation_action'], 'auto_submit');
    });

    test(
      'two refused edits of one field end on what the server holds',
      () async {
        final _Held server = _Held();
        final AppStore s = server.store();
        await s.loadAssessment('7');

        final Future<void> first = s.updateAsm(
          s.asmById('7')!.copyWith(aiMaxViolations: 2),
        );
        final Future<void> second = s.updateAsm(
          s.asmById('7')!.copyWith(aiMaxViolations: 4),
        );
        await pumpEventQueue();

        server.gates[0].complete(false);
        await first;
        server.gates[1].complete(false);
        await second;

        expect(s.asmById('7')!.aiMaxViolations, 5, reason: 'never 2');
      },
    );
  });
}

/// A server whose `/update` replies each wait on their own gate: true takes
/// the edit, false refuses it. The detail route serves what it holds.
class _Held {
  final Map<String, dynamic> stored = <String, dynamic>{..._detail};
  final List<Completer<bool>> gates = <Completer<bool>>[];

  AppStore store() {
    final AppStore s = AppStore(
      api: ApiClient(
        baseUrl: 'http://x',
        client: MockClient((http.Request req) async {
          final String p = req.url.path;
          if (p.endsWith('/update')) {
            final Completer<bool> gate = Completer<bool>();
            gates.add(gate);
            final Map<String, dynamic> edit =
                jsonDecode(req.body) as Map<String, dynamic>;
            if (!await gate.future) {
              return _reply(<String, dynamic>{
                'ok': false,
                'error': <String, dynamic>{
                  'code': 'invalid',
                  'message': 'Not while candidates are sitting it.',
                },
              }, 409);
            }
            stored.addAll(edit);
            return _reply(<String, dynamic>{'ok': true, 'data': stored}, 200);
          }
          if (p.endsWith('/assessments/7')) {
            return _reply(<String, dynamic>{'ok': true, 'data': stored}, 200);
          }
          if (p.endsWith('/assessments')) {
            return _reply(<String, dynamic>{
              'ok': true,
              'data': <dynamic>[
                <String, dynamic>{'id': 7, 'name': 'Hindi clips'},
              ],
              'meta': <String, dynamic>{'total': 1},
            }, 200);
          }
          return _reply(<String, dynamic>{
            'ok': true,
            'data': <dynamic>[],
          }, 200);
        }),
      ),
    );
    addTearDown(s.dispose);
    return s;
  }
}
