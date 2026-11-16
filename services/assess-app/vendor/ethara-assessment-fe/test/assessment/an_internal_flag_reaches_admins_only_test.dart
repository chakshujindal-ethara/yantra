// D1 - the operator's flag and remark, on the client side.
//
// THE DESIGN THIS PINS, because it reversed once and the reversal is the
// interesting part:
//
//   * the flag belongs to ONE SITTING, not to the person. A concern about how
//     somebody sat assessment A says nothing about their attempt on B, so
//     flagging one must leave the other alone. The earlier person-level design
//     patched every attempt a candidate had ever sat; that is now a bug and
//     `the flag stays on the sitting it was raised on` is what catches it.
//   * the flag and the remark are INDEPENDENT. Either can be set without the
//     other, and setting one must not disturb the other - which is a property
//     of the WIRE (a key that is not sent is not changed), so it is asserted
//     against the request body rather than against the resulting state alone.
//   * a payload with no flag block parses to nothing at all. The client is not
//     the disclosure boundary - the server omits the key from every
//     candidate-facing serializer, and `test_api_invariants.py` walks them
//     recursively to prove it - but a client that invented a default, or
//     rendered an empty badge, would still leak that the mechanism exists.
@TestOn('vm')
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';

/// An ADMIN row. [flag] is the block the server puts on `evaluator_admin_row`
/// and on no candidate serializer.
Map<String, dynamic> adminRow(
  String id,
  String personId,
  String name, {
  Map<String, dynamic>? flag,
  String assessmentId = '58',
}) => <String, dynamic>{
  'id': id,
  'assessment_id': assessmentId,
  'candidate': <String, dynamic>{'id': personId, 'name': name},
  'state': 'submitted',
  'answered_count': 13,
  'total_questions': 19,
  'flags': <String, dynamic>{'manual_flagged': (flag?['flagged'] ?? false)},
  'candidate_flag': ?flag,
};

const Map<String, dynamic> raised = <String, dynamic>{
  'flagged': true,
  'remark': 'Webcam showed a second person at 14:03.',
  'by': 'Akshay Kumar',
  'at': '2026-09-08T09:15:00',
};

class _Rig {
  final List<({String path, Map<String, dynamic> body})> calls =
      <({String path, Map<String, dynamic> body})>[];
  late final AppStore store;

  /// Per-ATTEMPT flag state, keyed by attempt id. The server owns it; the mock
  /// mirrors that so a refresh after a mutation agrees with the write.
  final Map<String, Map<String, dynamic>> flags = <String, Map<String, dynamic>>{};

  List<(String, String, String, String)> cohort =
      <(String, String, String, String)>[
    ('1723', 'p1', 'Aahan Trikha', '58'),
    ('9001', 'p1', 'Aahan Trikha', '60'),
    ('1481', 'p2', 'Jaahanvi', '58'),
  ];

  List<Map<String, dynamic>> get rows => <Map<String, dynamic>>[
    for (final (String, String, String, String) c in cohort)
      adminRow(c.$1, c.$2, c.$3, assessmentId: c.$4, flag: flags[c.$1]),
  ];

  ({String path, Map<String, dynamic> body}) get lastFlagCall => calls.lastWhere(
      (({String path, Map<String, dynamic> body}) c) => c.path.endsWith('/flag'));

  void init() {
    store = AppStore(
      api: ApiClient(
        client: MockClient((http.Request req) async {
          final String path = req.url.path;
          final Map<String, dynamic> body = req.body.isEmpty
              ? <String, dynamic>{}
              : jsonDecode(req.body) as Map<String, dynamic>;
          calls.add((path: path, body: body));

          final RegExpMatch? flagCall =
              RegExp(r'/attempts/([^/]+)/flag$').firstMatch(path);
          if (flagCall != null) {
            final String id = flagCall.group(1)!;
            final Map<String, dynamic> now =
                Map<String, dynamic>.from(flags[id] ??
                    <String, dynamic>{'flagged': false, 'remark': ''});
            // THE SERVER CONTRACT THE CLIENT DEPENDS ON: only the keys that
            // arrive are changed. A mock that overwrote both would hide the
            // very bug these tests exist to catch.
            if (body.containsKey('flagged')) {
              now['flagged'] = body['flagged'] == true;
              now['by'] = now['flagged'] == true ? 'Akshay Kumar' : '';
              now['at'] = now['flagged'] == true ? '2026-09-08T09:15:00' : '';
            }
            if (body.containsKey('remark')) now['remark'] = body['remark'];
            flags[id] = now;
            return _json(<String, dynamic>{
              'attempt_id': id,
              'candidate_flag': now,
            });
          }
          // `/assessments` MUST be served. `_loadAttempts()` clears the
          // attempt cache outright when `store.assessments` is empty, so a
          // mock that skipped this route made every post-mutation refresh wipe
          // the very state under test - and intermittently, depending on
          // whether the background refresh landed before the assertion.
          if (path.endsWith('/assessments')) {
            return _json(<dynamic>[
              for (final String id in <String>['58', '60'])
                <String, dynamic>{
                  'id': id,
                  'name': 'Assessment $id',
                  'state': 'done',
                  'active': true,
                },
            ]);
          }
          if (path.endsWith('/attempts')) return _json(rows, total: rows.length);
          final RegExpMatch? one =
              RegExp(r'/attempts/([^/]+)$').firstMatch(path);
          if (one != null) {
            final String want = one.group(1)!;
            return _json(rows.firstWhere(
                (Map<String, dynamic> r) => r['id'] == want,
                orElse: () => <String, dynamic>{}));
          }
          if (path.endsWith('/candidates')) {
            final bool only = body['manual_flagged_only'] == true;
            final List<Map<String, dynamic>> out = only
                ? rows
                      .where((Map<String, dynamic> r) =>
                          (r['candidate_flag'] as Map<String, dynamic>?)
                              ?['flagged'] ==
                          true)
                      .toList()
                : rows;
            return _json(out, total: out.length);
          }
          return _json(<String, dynamic>{});
        }),
        baseUrl: 'http://x',
      ),
    );
    store.accessRole = AccessRole.admin;
    store.caps = Capability.values.toSet();
    store.attempts = rows.map(Attempt.fromJson).toList();
  }

  static http.Response _json(Object data, {int? total}) => http.Response(
    jsonEncode(<String, dynamic>{
      'ok': true,
      'data': data,
      if (data is List)
        'meta': <String, dynamic>{
          'total': total ?? data.length,
          'limit': 200,
          'offset': 0,
          'has_more': false,
        },
    }),
    200,
    headers: <String, String>{'content-type': 'application/json'},
  );
}

void main() {
  group('the flag never invents itself', () {
    test('a payload with no flag block parses to none', () {
      final Attempt a = Attempt.fromJson(<String, dynamic>{
        'id': '1',
        'assessment_id': '58',
        'candidate': <String, dynamic>{'id': 'p1', 'name': 'Aahan Trikha'},
      });
      expect(a.candidateFlag.flagged, isFalse);
      expect(a.candidateFlag.hasRemark, isFalse);
      expect(a.candidateFlag.isEmpty, isTrue);
      expect(identical(a.candidateFlag, CandidateFlag.none), isTrue);
    });

    test('an explicit flagged:false with no remark is still nothing', () {
      final Attempt a = Attempt.fromJson(<String, dynamic>{
        'id': '1',
        'candidate_flag': <String, dynamic>{'flagged': false, 'remark': ''},
      });
      expect(a.candidateFlag.isEmpty, isTrue);
    });

    test('a REMARK with no flag survives parsing', () {
      // The regression this pins: the parser used to return `none` whenever
      // `flagged` was false, which silently dropped every remark an operator
      // left without also flagging the attempt - and the two are independent.
      final Attempt a = Attempt.fromJson(<String, dynamic>{
        'id': '1',
        'candidate_flag': <String, dynamic>{
          'flagged': false,
          'remark': 'Asked for a re-sit; approved by ops.',
        },
      });
      expect(a.candidateFlag.flagged, isFalse);
      expect(a.candidateFlag.hasRemark, isTrue);
      expect(a.candidateFlag.remark, contains('re-sit'));
      expect(a.candidateFlag.isEmpty, isFalse);
    });
  });

  group('the tooltip sentence', () {
    test('reads exactly as specified', () {
      const CandidateFlag f = CandidateFlag(
        flagged: true, by: 'Akshay Kumar', at: '2026-09-08T09:15:00');
      expect(f.raisedSentence, 'Raised by Akshay Kumar on Sep 8th, 2026');
    });

    test('an unflagged attempt has no sentence', () {
      expect(const CandidateFlag(remark: 'x').raisedSentence, isEmpty);
    });

    test('ordinals follow English, including the 11-13 exception', () {
      String d(int day) => ordinalDate(DateTime(2026, 9, day));
      expect(d(1), 'Sep 1st, 2026');
      expect(d(2), 'Sep 2nd, 2026');
      expect(d(3), 'Sep 3rd, 2026');
      expect(d(4), 'Sep 4th, 2026');
      // The three a naive `% 10` gets wrong.
      expect(d(11), 'Sep 11th, 2026');
      expect(d(12), 'Sep 12th, 2026');
      expect(d(13), 'Sep 13th, 2026');
      expect(d(21), 'Sep 21st, 2026');
      expect(d(22), 'Sep 22nd, 2026');
      expect(d(23), 'Sep 23rd, 2026');
    });
  });

  group('the flag stays on the sitting it was raised on', () {
    test('flagging one attempt leaves the same person elsewhere alone',
        () async {
      final _Rig r = _Rig()..init();
      // '1723' and '9001' are the SAME PERSON on two assessments.
      await r.store.flagAttempt('1723', flagged: true);

      final Map<String, Attempt> by = <String, Attempt>{
        for (final Attempt a in r.store.attempts) a.id: a,
      };
      expect(by['1723']!.candidateFlag.flagged, isTrue);
      expect(by['9001']!.candidateFlag.flagged, isFalse,
          reason: 'the flag is per-SITTING - the same candidate on another '
              'assessment must not inherit it');
      expect(by['1481']!.candidateFlag.flagged, isFalse);
    });

    test('the request names the attempt, not the person', () async {
      final _Rig r = _Rig()..init();
      await r.store.flagAttempt('1723', flagged: true);
      expect(r.lastFlagCall.path, contains('/attempts/1723/flag'));
    });

    test('clicking again clears it', () async {
      final _Rig r = _Rig()..init();
      await r.store.flagAttempt('1723', flagged: true);
      expect(r.store.attempts.firstWhere((Attempt a) => a.id == '1723')
          .candidateFlag.flagged, isTrue);

      await r.store.flagAttempt('1723', flagged: false);
      expect(r.store.attempts.firstWhere((Attempt a) => a.id == '1723')
          .candidateFlag.flagged, isFalse,
          reason: 'the toggle is the only clear action there is');
    });
  });

  group('flag and remark are independent', () {
    test('toggling the flag sends no remark key at all', () async {
      final _Rig r = _Rig()..init();
      await r.store.flagAttempt('1723', flagged: true);

      expect(r.lastFlagCall.body.containsKey('flagged'), isTrue);
      expect(r.lastFlagCall.body.containsKey('remark'), isFalse,
          reason: 'a key the server does not receive is a key it does not '
              'change - sending an empty remark here would wipe one');
    });

    test('editing the remark sends no flagged key at all', () async {
      final _Rig r = _Rig()..init();
      await r.store.flagAttempt('1723', remark: 'Approved a re-sit.');

      expect(r.lastFlagCall.body['remark'], 'Approved a re-sit.');
      expect(r.lastFlagCall.body.containsKey('flagged'), isFalse,
          reason: 'editing a remark must not raise or clear the flag');
    });

    test('a remark survives the flag being toggled off', () async {
      final _Rig r = _Rig()..init();
      await r.store.flagAttempt('1723', remark: 'Kept.');
      await r.store.flagAttempt('1723', flagged: true);
      await r.store.flagAttempt('1723', flagged: false);

      final Attempt a =
          r.store.attempts.firstWhere((Attempt x) => x.id == '1723');
      expect(a.candidateFlag.flagged, isFalse);
      expect(a.candidateFlag.remark, 'Kept.',
          reason: 'the remark is not a property of the flag');
    });

    test('a remark can be set on an attempt that was never flagged', () async {
      final _Rig r = _Rig()..init();
      await r.store.flagAttempt('1481', remark: 'Left early, ops aware.');

      final Attempt a =
          r.store.attempts.firstWhere((Attempt x) => x.id == '1481');
      expect(a.candidateFlag.flagged, isFalse);
      expect(a.candidateFlag.hasRemark, isTrue);
    });

    test('an empty remark clears it, and is not confused with absent',
        () async {
      final _Rig r = _Rig()..init();
      await r.store.flagAttempt('1723', remark: 'temporary');
      await r.store.flagAttempt('1723', remark: '');

      expect(r.lastFlagCall.body.containsKey('remark'), isTrue,
          reason: 'clearing is an explicit empty string, not an omitted key');
      expect(r.store.attempts.firstWhere((Attempt a) => a.id == '1723')
          .candidateFlag.hasRemark, isFalse);
    });
  });

  group('the roster filter narrows on the server', () {
    test('the flag filter is its own term', () async {
      final _Rig r = _Rig()..init();
      await r.store.loadRoster('58', manualFlaggedOnly: true);
      final ({String path, Map<String, dynamic> body}) call = r.calls
          .lastWhere((({String path, Map<String, dynamic> body}) c) =>
              c.path.endsWith('/candidates'));
      expect(call.body['manual_flagged_only'], isTrue);
      expect(call.body.containsKey('state'), isFalse,
          reason: 'the two filters compose rather than replacing each other');
    });

    test('an unfiltered roster read carries no such term', () async {
      final _Rig r = _Rig()..init();
      await r.store.loadRoster('58');
      final ({String path, Map<String, dynamic> body}) call = r.calls
          .lastWhere((({String path, Map<String, dynamic> body}) c) =>
              c.path.endsWith('/candidates'));
      expect(call.body.containsKey('manual_flagged_only'), isFalse);
    });
  });
}
