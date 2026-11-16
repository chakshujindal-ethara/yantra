// Three reported defects, all of them "the data was there and nobody read it".
//
//  1. LABELLING ANSWERS WERE INVISIBLE. An image_label answer is stored in the
//     same `justification` column as subjective prose, as a JSON object keyed
//     by box number. Only the candidate's exam runner ever decoded it, so the
//     admin screens read an empty map and printed "No boxes labelled" over a
//     question the candidate had filled in, and the candidate's own released
//     results sheet printed them the raw JSON of what they had typed.
//
//  2. THE VIOLATION CAP DID NOT FIRE. Ending required `violation_action ==
//     auto_submit`, so an assessment saved with "Violations Allowed Before
//     Auto-Submit = 20" AND "On Violation = Log only" ran straight past 20 -
//     one live sitting reached 26 with the paper still open. Two settings that
//     contradict each other, and the silent winner was the one that did
//     nothing.
//
//  3. NOBODY WAS TOLD WHY. An auto-submitted attempt carried no reason, so
//     both UIs had to guess between "hit the proctoring threshold" and "ran
//     out of time" - and the admin screen asserted the first for either.
library;

import 'dart:convert';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Exactly what `serializers.split_label_answers` now puts on the wire, taken
/// from a real sitting (assessment 843, response on the Text-to-Image paper).
const Map<String, dynamic> _liveLabels = <String, dynamic>{
  '46': 'it is cookies policy',
  '1': 'spotify icon',
};

void main() {
  group('labelling answers survive the wire', () {
    test('the admin response reads `label_answers`, not just `labels`', () {
      final Response r = Response.fromJson(<String, dynamic>{
        'id': 5,
        'question_type': 'image_label',
        'label_answers': _liveLabels,
      });

      // Was null before the fix - the parser looked only for `labels`, which
      // no module payload has ever contained. That null is what the admin
      // screen turned into "No boxes labelled".
      expect(r.labels, isNotNull);
      expect(r.labels!.length, 2);
      expect(r.labels![1], 'spotify icon');
      expect(r.labels![46], 'it is cookies policy');
    });

    test('the fixtures\' `labels` spelling still parses', () {
      final Response r = Response.fromJson(<String, dynamic>{
        'id': 5,
        'labels': <String, dynamic>{'2': 'nav bar'},
      });
      expect(r.labels, <int, String>{2: 'nav bar'});
    });

    test('a non-labelling answer keeps a null map', () {
      final Response r = Response.fromJson(<String, dynamic>{'id': 5});
      expect(r.labels, isNull);
    });

    test("the candidate's results row decodes them and orders by box", () {
      final AnswerSheetRow row = AnswerSheetRow.fromJson(<String, dynamic>{
        'index': 3,
        'question_type': 'image_label',
        'label_answers': _liveLabels,
        // Blanked by the module now that the map carries the answer. Before
        // the fix this held the raw JSON and was printed verbatim.
        'justification': '',
      }, released: true);

      expect(row.labelAnswers.length, 2);
      // BOX ORDER, not insertion order: the map arrives in whatever order the
      // candidate filled the boxes, and 46-before-1 cannot be read back
      // against the image.
      expect(
        row.labelLines.map((MapEntry<int, String> e) => e.key).toList(),
        <int>[1, 46],
      );
      expect(row.labelLines.first.value, 'spotify icon');
    });

    test('a labelled answer counts as answered', () {
      // `hasInput` was `chosen.isNotEmpty || justification.isNotEmpty`, and a
      // labelling answer has neither once the JSON moves out of the prose - so
      // decoding it without this would have told the candidate they had
      // skipped a question they answered.
      final AnswerSheetRow row = AnswerSheetRow.fromJson(<String, dynamic>{
        'question_type': 'image_label',
        'label_answers': _liveLabels,
        'justification': '',
      }, released: true);
      expect(row.hasInput, isTrue);
    });

    test('blank boxes are dropped, and an all-blank answer is not input', () {
      final AnswerSheetRow row = AnswerSheetRow.fromJson(<String, dynamic>{
        'question_type': 'image_label',
        'label_answers': <String, dynamic>{'1': '  ', '2': ''},
      }, released: true);
      expect(row.labelLines, isEmpty);
      expect(row.hasInput, isFalse);
    });
  });

  group('log only means log only', () {
    test('cap 3 + log_only records all three and ends nothing', () async {
      final _Rig rig = _Rig(maxViolations: 3, violationAction: 'log_only');
      rig.watch();

      // Distinct reasons: the 1.2s same-reason dedup would otherwise fold
      // these into one and the test would prove nothing.
      rig.store.recordViolation('7', 'Tab switched / window hidden');
      rig.store.recordViolation('7', 'Exited fullscreen');
      rig.store.recordViolation('7', 'Right-click attempted');

      expect(
        rig.everEnded,
        isFalse,
        reason:
            'the operator chose the one action whose whole promise is "record '
            'it, do not act on it" - reaching the cap must not end the sitting',
      );
      // The count still rises: a limit under log-only is what the operator
      // reads afterwards, so it has to be counted even though nothing acts.
      expect(rig.store.attemptById('7')!.violationCount, 3);
      await rig.settle();
    });

    test('cap 2 + auto_submit still ends on the second', () async {
      // The other half of the contract: an auto action is the thing that may
      // end a sitting, and the cap says when. Live, the server ends it and
      // says so, and only then does this client (BR-D1).
      final _Rig rig = _Rig(
        maxViolations: 2,
        violationAction: 'auto_submit',
        serverEndsAt: 2,
      );
      rig.watch();

      rig.store.recordViolation('7', 'Tab switched / window hidden');
      await rig.settle();
      expect(
        rig.everEnded,
        isFalse,
        reason: 'one of an allowed two must not end it',
      );

      rig.store.recordViolation('7', 'Exited fullscreen');
      expect(rig.everEnded, isFalse, reason: 'not before the server says so');
      await rig.settle();
      expect(rig.everEnded, isTrue);
      expect(rig.endedWith, 'violation');
    });

    test('log_only with NO cap still never ends it', () async {
      final _Rig rig = _Rig(maxViolations: 0, violationAction: 'log_only');
      rig.watch();
      for (final String r in <String>['a', 'b', 'c', 'd', 'e']) {
        rig.store.recordViolation('7', r);
      }
      expect(rig.everEnded, isFalse);
      await rig.settle();
    });

    test('auto_submit with no cap still ends on the first', () async {
      final _Rig rig = _Rig(
        maxViolations: 0,
        violationAction: 'auto_submit',
        serverEndsAt: 1,
      );
      rig.watch();
      rig.store.recordViolation('7', 'Exited fullscreen');
      await rig.settle();
      expect(rig.everEnded, isTrue);
    });
  });

  group('the auto-submit reason reaches the client', () {
    test('it is read from the top level and from `proctoring`', () {
      expect(
        Attempt.fromJson(<String, dynamic>{
          'id': 7,
          'assessment_id': 18,
          'auto_submit_reason': 'violation',
        }).autoSubmitReason,
        'violation',
      );
      expect(
        Attempt.fromJson(<String, dynamic>{
          'id': 7,
          'assessment_id': 18,
          'proctoring': <String, dynamic>{'auto_submit_reason': 'expired'},
        }).autoSubmitReason,
        'expired',
      );
    });

    test('a self-submitted paper carries no reason', () {
      expect(
        Attempt.fromJson(<String, dynamic>{
          'id': 7,
          'assessment_id': 18,
          'state': 'submitted',
        }).autoSubmitReason,
        '',
      );
    });
  });
}

/// One live in-progress sitting whose `/violation` route answers "recorded,
/// not ended" - unless [serverEndsAt] is set, from that report on - so a
/// sitting can only end where the cap policy and the server's word agree.
class _Rig {
  _Rig({
    required int maxViolations,
    required String violationAction,
    int serverEndsAt = 0,
  }) {
    int reports = 0;
    store = AppStore(
      api: ApiClient(
        client: MockClient((http.Request req) async {
          final bool violation = req.url.path.endsWith('/violation');
          if (violation) reports++;
          final Map<String, dynamic> data = violation
              ? <String, dynamic>{
                  'recorded': true,
                  'attempt_ended': serverEndsAt > 0 && reports >= serverEndsAt,
                }
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
        'max_violations': maxViolations,
        'violation_action': violationAction,
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
  bool everEnded = false;

  /// The reason the sitting ended with, read as it ended: the re-read after
  /// the ending replaces the rows.
  String? endedWith;

  void watch() => store.addListener(() {
    final Attempt? a = store.attemptById('7');
    if (a?.isDone ?? false) {
      everEnded = true;
      endedWith ??= a!.autoSubmitReason;
    }
  });

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 20));
}
