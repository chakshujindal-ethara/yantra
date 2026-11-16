// FOUR THINGS THE SERVER HAS ALWAYS SENT AND NO CLIENT EVER READ.
//
// Each of these was a key on the wire with no consumer in Dart, which is the
// quietest kind of defect: the payload is correct, the tests pass, and the
// feature simply is not there. All four were visible on the server-rendered
// runner this app replaced, so each is a capability the port dropped.
//
//   1. `preview` - `/exam/<token>/state` sets it when the caller holds the token
//      but is not the candidate. `ExamView.preview` PARSED it and nothing read
//      it, so staff got the full consent page and a live-looking "Start
//      Assessment" button, then a `wrong_candidate` refusal from `_write_guard`
//      on pressing it.
//   2. `poster_url` - the still frame a clip shows before playing. Every video
//      opened as a black rectangle: nothing said what it was of, or whether it
//      had loaded rather than failed.
//   3. `violation_reason` - on `/me/assessments`. The card printed
//      "1 proctoring violation(s) recorded." - a number, an unfinished
//      template, and no way to know WHAT was recorded.
//   4. `breakdown` - NEW on `candidate_result`, structured rather than the
//      server's HTML card. "6 / 10" tells a candidate they failed and nothing
//      about which half they lost it on.
library;

import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('preview reaches the client', () {
    test('ExamView parses the flag the server sets', () {
      final ExamView live = ExamView.fromJson(<String, dynamic>{
        'outcome': 'instructions',
      });
      final ExamView preview = ExamView.fromJson(<String, dynamic>{
        'outcome': 'instructions',
        'preview': true,
      });

      expect(live.preview, isFalse);
      expect(
        preview.preview,
        isTrue,
        reason: 'the flag is the only thing that can tell staff reading a '
            'candidate paper apart from the candidate; the server decides it, '
            'never the client',
      );
    });
  });

  group('a video carries its poster frame', () {
    test('poster_url is parsed off the asset', () {
      final Asset a = Asset.fromJson(<String, dynamic>{
        'id': 7,
        'label': 'Clip',
        'url': '/assessments_be/exam/qvideo/tok/7',
        'poster_url': '/assessments_be/exam/qimage/tok/9',
      });
      expect(a.posterUrl, '/assessments_be/exam/qimage/tok/9');
    });

    test('an empty poster is ABSENT, not a URL that cannot load', () {
      // The serializer sends "" for a clip with no poster. Taken literally that
      // becomes a src the browser tries and fails, so the plate would show a
      // broken-image frame instead of the video's own first frame.
      final Asset a = Asset.fromJson(<String, dynamic>{
        'id': 7,
        'label': 'Clip',
        'url': '/x',
        'poster_url': '',
      });
      expect(a.posterUrl, isNull);
    });

    test('copyWith carries the poster rather than blanking it', () {
      // `copyWith` is how `label_boxes` get attached to an asset the payload
      // already built, so dropping the poster there would blank it on exactly
      // the questions that go through that path.
      final Asset a = Asset.fromJson(<String, dynamic>{
        'id': 7,
        'label': 'Clip',
        'url': '/x',
        'poster_url': '/poster.png',
      });
      expect(a.copyWith(regions: const <LabelRegion>[]).posterUrl, '/poster.png');
    });

    test('the poster round-trips through toJson', () {
      final Asset a = Asset.fromJson(<String, dynamic>{
        'id': 7,
        'label': 'Clip',
        'url': '/x',
        'poster_url': '/poster.png',
      });
      expect(Asset.fromJson(a.toJson()).posterUrl, '/poster.png');
    });
  });

  group('the released result is split by section', () {
    /// A released `/exam/<token>/answers` payload.
    ///
    /// `breakdown` defaults to an EMPTY LIST meaning "the key is absent", which
    /// is the shape an older server sends and one of the cases below. An empty
    /// list and a missing key are indistinguishable to the parser, so the test
    /// does not need to tell them apart - and expressing "absent" this way keeps
    /// the map literal free of a conditional entry.
    Map<String, dynamic> sheet({
      List<Map<String, dynamic>> breakdown = const <Map<String, dynamic>>[],
    }) {
      final Map<String, dynamic> result = <String, dynamic>{
        'released': true,
        'score_marks': '6 / 10',
        'result': 'fail',
      };
      if (breakdown.isNotEmpty) result['breakdown'] = breakdown;
      return <String, dynamic>{
        'assessment': <String, dynamic>{'name': 'Quality Assessment'},
        'result': result,
        'rows': <dynamic>[],
      };
    }

    test('the breakdown is parsed off the released block', () {
      final AnswerSheet s = AnswerSheet.fromJson(
        sheet(
          breakdown: <Map<String, dynamic>>[
            <String, dynamic>{
              'key': 'objective',
              'label': 'Objective',
              'value': 5,
              'total': 7,
              'unit': 'correct',
            },
            <String, dynamic>{
              'key': 'subjective',
              'label': 'Written',
              'value': 1,
              'total': 3,
              'unit': 'passed',
              'pending': 1,
            },
          ],
        ),
      );

      expect(s.resultSections, hasLength(2));
      expect(s.resultSections.first.summary, '5 of 7 correct');
      expect(s.resultSections.last.summary, '1 of 3 passed');
      expect(
        s.resultSections.last.pending,
        1,
        reason: 'a section still being graded must say so - "1 of 3 passed" '
            'reads as final and is not while a judge is running',
      );
    });

    test('an UNRELEASED sheet carries no breakdown at all', () {
      // Invariant 3: nothing about a score reaches a candidate before a person
      // releases it. The gate is applied while PARSING, so a screen cannot
      // disclose the split by forgetting to check - the value is not in the
      // object.
      final AnswerSheet s = AnswerSheet.fromJson(<String, dynamic>{
        'assessment': <String, dynamic>{'name': 'Quality Assessment'},
        'result': <String, dynamic>{
          'released': false,
          'breakdown': <Map<String, dynamic>>[
            <String, dynamic>{
              'key': 'objective',
              'label': 'Objective',
              'value': 5,
              'total': 7,
              'unit': 'correct',
            },
          ],
        },
        'rows': <dynamic>[],
      });

      expect(
        s.resultSections,
        isEmpty,
        reason: 'a breakdown on an unreleased payload must still be dropped - '
            'the parse is the gate',
      );
    });

    test('a paper with no written section renders one row fewer', () {
      final AnswerSheet s = AnswerSheet.fromJson(
        sheet(
          breakdown: <Map<String, dynamic>>[
            <String, dynamic>{
              'key': 'objective',
              'label': 'Objective',
              'value': 9,
              'total': 9,
              'unit': 'correct',
            },
          ],
        ),
      );
      expect(s.resultSections.single.key, 'objective');
    });

    test('a server that sends no breakdown is not an error', () {
      final AnswerSheet s = AnswerSheet.fromJson(sheet());
      expect(s.resultSections, isEmpty);
      expect(s.released, isTrue, reason: 'the rest of the sheet still parses');
    });

    test('a section round-trips through toJson', () {
      const ResultSection s = ResultSection(
        key: 'objective',
        label: 'Objective',
        value: 5,
        total: 7,
        unit: 'correct',
        pending: 2,
      );
      final ResultSection back = ResultSection.fromJson(s.toJson());
      expect(back.summary, s.summary);
      expect(back.pending, 2);
      expect(back.key, 'objective');
    });
  });

  group('a violation names its reason', () {
    test('the attempt parses violation_reason for the candidate card', () {
      final Attempt a = Attempt.fromJson(<String, dynamic>{
        'id': 3,
        'assessment_id': 1,
        'token': 'tok',
        'violation_count': 2,
        'violation_reason': 'Tab switched or window hidden',
      });

      expect(a.violationCount, 2);
      expect(
        a.violationReason,
        'Tab switched or window hidden',
        reason: 'somebody told they broke a rule is entitled to know which one',
      );
    });
  });
}
