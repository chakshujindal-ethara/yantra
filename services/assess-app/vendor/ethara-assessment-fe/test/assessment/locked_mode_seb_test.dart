// Locked mode: the "Require Safe Exam Browser" rule, on the wire and on screen.
//
// THE CONTRACT (ETP plans, Part 11 §11.3). The rule reads as `seb` in the rules
// block and writes as `rule_require_seb`. `/state` answers `seb_required` with
// a `seb` block of links. Inside SEB every candidate exam call carries the
// proof - `seb_url` (the page URL at load) and `seb_key`
// (`SafeExamBrowser.security.configKey`) - and a write without it is refused
// with 403 `seb_required`, which must put the gate back up rather than toast.
//
// The frontend and the backend deploy separately, so a server that predates
// the rule omits `seb` entirely; that has to read as OFF, never as a throw.
library;

import 'dart:convert';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/exam/exam_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const String _token = 'tok';

const Map<String, dynamic> _links = <String, dynamic>{
  'launch_url': 'sebs://x/api/v1/exam/tok/seb-config',
  'download_url': 'https://safeexambrowser.org/download_en.html',
  'quit_url': 'https://x/exam/tok/quit',
};

/// The rule block as a server from before the rule sends it: no `seb` key.
Map<String, dynamic> _oldRules() => <String, dynamic>{
  'tab_switch': true,
  'copy_paste': true,
  'right_click': true,
  'devtools': true,
  'fullscreen': true,
  'webcam': false,
  'watermark': true,
};

http.Response _ok(Map<String, dynamic> data) => http.Response(
  jsonEncode(<String, dynamic>{'ok': true, 'data': data}),
  200,
  headers: <String, String>{'content-type': 'application/json'},
);

/// A client that records every request body, answering each with [answer].
ApiClient _recording(
  List<http.Request> seen, {
  Map<String, String> Function()? sebProof,
  http.Response Function(http.Request req)? answer,
}) => ApiClient(
  client: MockClient((http.Request req) async {
    seen.add(req);
    return answer?.call(req) ?? _ok(<String, dynamic>{});
  }),
  baseUrl: 'http://x',
  sebProof: sebProof,
);

Map<String, dynamic> _body(http.Request r) =>
    jsonDecode(r.body) as Map<String, dynamic>;

/// All six candidate exam calls, in route order.
Future<void> _everyExamCall(ApiClient api) async {
  await api.examState(_token);
  await api.examBegin(_token);
  await api.examAnswer(_token, questionId: '5');
  await api.examReview(_token);
  await api.examSubmit(_token);
  await api.examViolation(_token, 'Tab switched');
}

void main() {
  group('the rule parses', () {
    test('a rules block without `seb` reads OFF', () {
      final Assessment a = Assessment.fromJson(<String, dynamic>{
        'id': 18,
        'rules': _oldRules(),
      });
      expect(a.rules[ProctorRule.seb], isFalse);
      // ...and the neighbours still read, so this is the key, not the block.
      expect(a.rules[ProctorRule.tabSwitch], isTrue);
    });

    test('`seb: true` reads ON', () {
      final Assessment a = Assessment.fromJson(<String, dynamic>{
        'id': 18,
        'rules': <String, dynamic>{..._oldRules(), 'seb': true},
      });
      expect(a.rules[ProctorRule.seb], isTrue);
    });

    test('a fresh rule set leaves it OFF, unlike every other rule', () {
      expect(RuleSet.defaults()[ProctorRule.seb], isFalse);
      expect(Assessment(id: '1', name: 'x').rules[ProctorRule.seb], isFalse);
    });
  });

  group('the switch is withdrawn from the settings screens', () {
    test('OFF, it is not offered; every other rule still is', () {
      final List<ProctorRule> offered = RuleSet.defaults().switches;
      expect(offered, isNot(contains(ProctorRule.seb)));
      expect(
        offered,
        ProctorRule.values.where((ProctorRule r) => r != ProctorRule.seb),
      );
    });

    test('ON, it stays offered, so it can be switched off', () {
      final RuleSet on = RuleSet.defaults().set(ProctorRule.seb, true);
      expect(on.switches, contains(ProctorRule.seb));
      expect(on.switches, ProctorRule.values);
    });

    test('the quit password comes off the admin detail', () {
      final Assessment a = Assessment.fromJson(<String, dynamic>{
        'id': 18,
        'rules': <String, dynamic>{..._oldRules(), 'seb': true},
        'seb_quit_password': '3f9a1c07be2d',
      });
      expect(a.sebQuitPassword, '3f9a1c07be2d');
      // An Odoo Char left empty arrives as `false`.
      expect(
        Assessment.fromJson(<String, dynamic>{
          'id': 18,
          'seb_quit_password': false,
        }).sebQuitPassword,
        '',
      );
    });
  });

  group('the /state envelope', () {
    test('parses `seb_required` and its links', () {
      final ExamView v = ExamView.fromJson(<String, dynamic>{
        'outcome': 'seb_required',
        'seb': _links,
      });
      expect(v.outcome, 'seb_required');
      expect(v.seb.launchUrl, 'sebs://x/api/v1/exam/tok/seb-config');
      expect(v.seb.downloadUrl, _links['download_url']);
      expect(v.seb.quitUrl, 'https://x/exam/tok/quit');
    });

    test('an envelope without the block has empty links', () {
      final ExamView v = ExamView.fromJson(<String, dynamic>{
        'outcome': 'instructions',
      });
      expect(v.seb.launchUrl, isEmpty);
      expect(v.seb.quitUrl, isEmpty);
    });

    test('the links survive a question-to-question copy', () {
      // `examAdvance` moves the runner with `copyWith`; the Complete screen
      // reads `quit_url` off whatever envelope the store holds at the end.
      final ExamView v = ExamView.fromJson(<String, dynamic>{
        'outcome': 'question',
        'seb': _links,
      }).copyWith(outcome: 'complete');
      expect(v.seb.quitUrl, 'https://x/exam/tok/quit');
    });
  });

  group('the proof rides on every candidate exam call', () {
    test('inside SEB: all six carry seb_url and seb_key', () async {
      final List<http.Request> seen = <http.Request>[];
      await _everyExamCall(
        _recording(
          seen,
          sebProof: () => <String, String>{
            'seb_url': 'https://x/exam/tok',
            'seb_key': 'abc123',
          },
        ),
      );
      expect(seen, hasLength(6));
      for (final http.Request r in seen) {
        expect(_body(r)['seb_url'], 'https://x/exam/tok', reason: r.url.path);
        expect(_body(r)['seb_key'], 'abc123', reason: r.url.path);
        // Beside the session key, not instead of it.
        expect(_body(r)['session_key'], isNotEmpty, reason: r.url.path);
      }
    });

    test('outside SEB: none of them carries either key', () async {
      final List<http.Request> seen = <http.Request>[];
      // No injection: the VM default is the stub, which is "not in SEB".
      await _everyExamCall(_recording(seen));
      expect(seen, hasLength(6));
      for (final http.Request r in seen) {
        expect(_body(r).containsKey('seb_url'), isFalse, reason: r.url.path);
        expect(_body(r).containsKey('seb_key'), isFalse, reason: r.url.path);
      }
    });
  });

  group('the rule is written as rule_require_seb', () {
    test('ProctorRule.seb names the field', () {
      expect(ProctorRule.seb.wire, 'seb');
      expect(ProctorRule.seb.field, 'rule_require_seb');
    });

    test('updateAssessment sends it', () async {
      final List<http.Request> seen = <http.Request>[];
      await _recording(seen).updateAssessment('18', requireSeb: true);
      expect(_body(seen.single)['rule_require_seb'], isTrue);
    });

    test('updateAsm sends it when the switch moved, and only then', () async {
      final List<http.Request> seen = <http.Request>[];
      final AppStore store = AppStore(api: _recording(seen));
      final Assessment asm = Assessment.fromJson(<String, dynamic>{
        'id': 18,
        'name': 'L1 Screening',
        'state': 'draft',
        'rules': _oldRules(),
      });
      store.assessments = <Assessment>[asm];

      await store.updateAsm(
        asm.copyWith(rules: asm.rules.set(ProctorRule.seb, true)),
      );

      final Map<String, dynamic> sent = _body(
        seen.firstWhere((http.Request r) => r.url.path.endsWith('/update')),
      );
      expect(sent['rule_require_seb'], isTrue);
      // Only what changed: the untouched rules stay off the body.
      expect(sent.containsKey('rule_fullscreen'), isFalse);
    });
  });

  testWidgets('the quit password survives a list refresh', (
    WidgetTester t,
  ) async {
    // Detail-only, like the roster and the pool: `assessment_row` does not
    // carry it, and `_act` ends every save with a list refresh. Same hazard
    // and rig shape as `shortlist_cache_merge_test.dart`.
    final Map<String, dynamic> row = <String, dynamic>{
      'id': '7',
      'name': 'L1 Screening',
      'state': 'draft',
    };
    final AppStore s = AppStore(
      api: ApiClient(
        baseUrl: 'http://x',
        client: MockClient((http.Request req) async {
          final String p = req.url.path;
          if (p.endsWith('/assessments')) {
            return http.Response(
              jsonEncode(<String, dynamic>{
                'ok': true,
                'data': <dynamic>[row],
                'meta': <String, dynamic>{'total': 1, 'has_more': false},
              }),
              200,
              headers: <String, String>{'content-type': 'application/json'},
            );
          }
          if (p.contains('/assessments/')) {
            return _ok(<String, dynamic>{
              ...row,
              'rules': <String, dynamic>{..._oldRules(), 'seb': true},
              'seb_quit_password': '3f9a1c07be2d',
            });
          }
          return http.Response(
            jsonEncode(<String, dynamic>{
              'ok': true,
              'data': <dynamic>[],
              'meta': <String, dynamic>{'total': 0, 'has_more': false},
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
      ),
    );
    addTearDown(s.dispose);
    s.adoptSession(
      orgRole: 'admin',
      name: 'Aarav Mehta',
      uid: '2',
      accessRoleWire: AccessRole.admin.wire,
      capabilities: Capability.values.toSet(),
    );
    await t.pumpWidget(const SizedBox.shrink());
    await t.pumpAndSettle();

    Assessment held() =>
        s.assessments.firstWhere((Assessment a) => a.id == '7');
    await s.loadAssessment('7');
    expect(held().sebQuitPassword, '3f9a1c07be2d');

    await s.refresh(background: true);
    expect(held().sebQuitPassword, '3f9a1c07be2d');
  });

  test('a write refused with 403 seb_required re-reads /state', () async {
    // The gate, not a toast: the server now answers `seb_required`, and the
    // exam screen renders that over the attempt it already holds.
    final List<http.Request> seen = <http.Request>[];
    final AppStore store = AppStore(
      api: _recording(
        seen,
        answer: (http.Request req) => req.url.path.endsWith('/state')
            ? _ok(<String, dynamic>{'outcome': 'seb_required', 'seb': _links})
            : http.Response(
                jsonEncode(<String, dynamic>{
                  'ok': false,
                  'error': <String, dynamic>{
                    'code': 'seb_required',
                    'message':
                        'This assessment opens only in Safe Exam '
                        'Browser.',
                  },
                }),
                403,
                headers: <String, String>{'content-type': 'application/json'},
              ),
      ),
    );

    await store.examAdvance(_token, '5', const Response(justification: 'x'));
    for (int i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }

    expect(
      seen.map((http.Request r) => r.url.path),
      contains('/api/v1/exam/$_token/state'),
    );
    expect(store.examView(_token)?.outcome, 'seb_required');
  });

  testWidgets('the seb_required gate offers SEB, never Start', (
    WidgetTester t,
  ) async {
    t.view.physicalSize = const Size(1400, 1800);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);

    // A sitting the store ALREADY holds - an attempt at instructions and its
    // assessment - so without the gate winning this would render the
    // instructions page and its Start button.
    final AppStore s = AppStore(
      api: ApiClient(
        client: MockClient(
          (http.Request req) async =>
              _ok(<String, dynamic>{'outcome': 'seb_required', 'seb': _links}),
        ),
        baseUrl: 'http://x',
        bearer: 'stub',
      ),
    )..portal = Portal.member;
    s.assessments = <Assessment>[
      Assessment.fromJson(<String, dynamic>{
        'id': 18,
        'name': 'L1 Screening',
        'state': 'in_progress',
        'rules': <String, dynamic>{..._oldRules(), 'seb': true},
      }),
    ];
    s.attempts = <Attempt>[
      Attempt.fromJson(<String, dynamic>{
        'id': 7,
        'assessment_id': 18,
        'access_token': _token,
        'state': 'pending',
      }),
    ];

    await t.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: AssessmentNavScope(
          nav: AssessmentNav(),
          child: ExamScreen(store: s, token: _token),
        ),
      ),
    );
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await t.pumpAndSettle();

    expect(find.text('Open this assessment in Safe Exam Browser'), findsOne);
    expect(find.text('Open in Safe Exam Browser'), findsOne);
    expect(find.text('Download Safe Exam Browser'), findsOne);
    expect(find.text('Start Assessment'), findsNothing);
  });
}
