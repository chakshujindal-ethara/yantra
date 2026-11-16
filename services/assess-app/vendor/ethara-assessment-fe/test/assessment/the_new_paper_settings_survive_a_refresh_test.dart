// `results_show_answers` (15 Oct, R6) is detail-only, like the quit password:
// `assessment_row` does not carry it, and `_act` ends every save with a list
// refresh. It has to survive that refresh, reach the wire when changed, and
// only then.
//
// Ported to main from stage (7518da8) with the R6 cases, and the R7
// transcription bar (`transcription_threshold`) beside them since 21 Oct; the
// AI pair (R5) cases on stage are not here.
library;

import 'dart:convert';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _ok(Object data) => http.Response(
  jsonEncode(<String, dynamic>{
    'ok': true,
    'data': data,
    if (data is List)
      'meta': <String, dynamic>{'total': data.length, 'has_more': false},
  }),
  200,
  headers: <String, String>{'content-type': 'application/json'},
);

class _Rig {
  _Rig() {
    store = AppStore(
      api: ApiClient(
        baseUrl: 'http://x',
        client: MockClient((http.Request req) async {
          final String p = req.url.path;
          if (p.endsWith('/update') || p.endsWith('/create')) {
            bodies.add(jsonDecode(req.body) as Map<String, dynamic>);
            return _ok(<String, dynamic>{'id': 9});
          }
          if (p.endsWith('/assessments')) return _ok(<dynamic>[row]);
          if (p.endsWith('/assessments/7')) return _ok(detail);
          return _ok(<dynamic>[]);
        }),
      ),
    );
    store.adoptSession(
      orgRole: 'admin',
      name: 'Aarav Mehta',
      uid: '2',
      accessRoleWire: AccessRole.admin.wire,
      capabilities: Capability.values.toSet(),
    );
  }

  late final AppStore store;
  final List<Map<String, dynamic>> bodies = <Map<String, dynamic>>[];

  /// A list row: none of the detail-only keys.
  final Map<String, dynamic> row = <String, dynamic>{
    'id': '7',
    'name': 'L1 Screening',
    'state': 'in_progress',
    'violation_action': 'log_only',
    'max_violations': 3,
  };

  final Map<String, dynamic> detail = <String, dynamic>{
    'id': '7',
    'name': 'L1 Screening',
    'state': 'in_progress',
    'violation_action': 'log_only',
    'max_violations': 3,
    'results_show_answers': false,
    'subjective_threshold': 70.0,
    'transcription_threshold': 85.0,
  };

  Assessment held() =>
      store.assessments.firstWhere((Assessment a) => a.id == '7');

  Future<void> open() async {
    await store.refresh();
    await store.loadAssessment('7');
  }
}

void main() {
  test('results_show_answers survives a list refresh', () async {
    final _Rig rig = _Rig();
    await rig.open();
    expect(rig.held().resultsShowAnswers, isFalse);

    await rig.store.refresh(background: true);
    expect(
      rig.held().resultsShowAnswers,
      isFalse,
      reason: 'R6: the switch reset',
    );
    expect(rig.held().transcriptionThreshold, 85.0, reason: 'R7');
  });

  /// The other half of the presence rule: a list row that DOES carry the key
  /// is the server's newer word, and replaces the held value.
  test('a list row that carries results_show_answers wins', () async {
    final _Rig rig = _Rig();
    await rig.open();
    expect(rig.held().resultsShowAnswers, isFalse);

    rig.row['results_show_answers'] = true;
    await rig.store.refresh(background: true);
    expect(rig.held().resultsShowAnswers, isTrue);
  });

  test('a list row that carries transcription_threshold wins', () async {
    final _Rig rig = _Rig();
    await rig.open();
    expect(rig.held().transcriptionThreshold, 85.0);

    rig.row['transcription_threshold'] = 95.0;
    await rig.store.refresh(background: true);
    expect(rig.held().transcriptionThreshold, 95.0);
  });

  test('a changed setting is sent, an unchanged one is not', () async {
    final _Rig rig = _Rig();
    await rig.open();

    await rig.store.updateAsm(rig.held().copyWith(resultsShowAnswers: true));
    expect(rig.bodies.last['results_show_answers'], isTrue);
    expect(rig.bodies.last.containsKey('transcription_threshold'), isFalse);

    await rig.store.updateAsm(rig.held().copyWith(transcriptionThreshold: 90));
    expect(rig.bodies.last['transcription_threshold'], 90.0);
    expect(rig.bodies.last.containsKey('results_show_answers'), isFalse);

    await rig.store.updateAsm(rig.held().copyWith(name: 'L2 Screening'));
    expect(rig.bodies.last['name'], 'L2 Screening');
    expect(rig.bodies.last.containsKey('results_show_answers'), isFalse);
  });

  test('a new paper sends its choice, and the default is on', () async {
    final _Rig rig = _Rig();
    await rig.store.addAssessment(
      Assessment(id: 'new', name: 'Fresh', resultsShowAnswers: false),
    );
    expect(rig.bodies.last['results_show_answers'], isFalse);

    await rig.store.addAssessment(Assessment(id: 'new2', name: 'Fresh 2'));
    expect(rig.bodies.last['results_show_answers'], isTrue);
  });

  test('a new paper sends its transcription bar', () async {
    final _Rig rig = _Rig();
    await rig.store.addAssessment(
      Assessment(id: 'new', name: 'Fresh', transcriptionThreshold: 80),
    );
    expect(rig.bodies.last['transcription_threshold'], 80.0);
  });

  test('it reads off the wire, true when absent', () {
    expect(
      Assessment.fromJson(<String, dynamic>{
        'id': 7,
        'results_show_answers': false,
      }).resultsShowAnswers,
      isFalse,
    );
    expect(
      Assessment.fromJson(<String, dynamic>{'id': 7}).resultsShowAnswers,
      isTrue,
    );
  });

  group('the bar a clip is judged by', () {
    Assessment paper(double t) => Assessment(
      id: '7',
      name: 'x',
      subjectiveThreshold: 70,
      transcriptionThreshold: t,
    );

    test('a transcription clip clears its own bar when one is set', () {
      expect(paper(85).barFor(QType.transcription), 85);
      expect(paper(85).barFor(QType.subjectiveRubric), 70);
    });

    test('0 follows the subjective bar', () {
      expect(paper(0).barFor(QType.transcription), 70);
    });

    test('it reads off the wire, a double first', () {
      expect(
        Assessment.fromJson(<String, dynamic>{
          'id': 7,
          'transcription_threshold': 90,
        }).transcriptionThreshold,
        90.0,
      );
      expect(
        Assessment.fromJson(<String, dynamic>{'id': 7}).transcriptionThreshold,
        0.0,
      );
    });
  });
}
