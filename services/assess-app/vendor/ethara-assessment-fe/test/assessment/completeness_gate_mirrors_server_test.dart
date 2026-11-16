// The runner's completeness gate must ask the SAME question the server asks.
//
// `examAdvance` held its own approximation of the rule:
//
//     needsProse = q.requiresJustification && r.justification.trim().isEmpty
//
// which refused two kinds of FULLY ANSWERED question on every Next press.
//
//   * image_label. Its answer lives in `labels`; `_LabelRow.onChanged` never
//     writes `justification`. The server does not disagree - `_record_response`
//     PACKS the label map INTO `justification` before applying this same test -
//     so a labelled question passes server-side while the client was still
//     looking at an empty string. The candidate saw "8 / 8 labelled" beside a
//     red "needs a justification before it counts".
//
//   * subjective_rubric answered on its axes. The server's `carried_by_axes`
//     accepts a rubric whose dimensions are answered and whose optional prose
//     box ("explain any FAILED check") is blank. The client had no equivalent.
//
// The toast was not the whole cost: `needsProse` also SKIPS the authoritative
// save, so the answer reached the server through the 1 s debounce instead. It
// lands, so nothing was lost - but the candidate is told the opposite of the
// truth and cannot tell a false alarm from real data loss. In an exam those are
// the same thing.
//
// These tests assert the PREDICATE against the server's own rule, in both
// directions, because the dangerous regression is not "the toast came back" - it
// is a gate that stops refusing something the server WILL refuse.
@TestOn('vm')
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';

/// The gate as `examAdvance` computes it.
///
/// CALLS THE PRODUCTION PREDICATE - it does not restate it. A transcribed copy
/// would pass against a gutted `satisfiesProse`, which is exactly the vacuous
/// shape this codebase already has too much of.
bool needsProse(Question q, Response r) =>
    q.requiresJustification && !r.satisfiesProse(q);

/// The rule as `controllers/api/candidate.py::_record_response` applies it,
/// transcribed. This is the oracle: the client is correct exactly when it
/// agrees with this.
///
///     subjective = type in (subjective_rubric, image_prompt, image_label,
///                           video_prompt)
///     carried_by_axes = type == subjective_rubric and dims and lines
///     if subjective and not justification and not carried_by_axes: refuse
///
/// with `justification` already carrying the packed label map for image_label.
bool serverWouldRefuse(Question q, Response r) {
  const Set<QType> subjective = <QType>{
    QType.subjectiveRubric,
    QType.imagePrompt,
    QType.imageLabel,
    QType.videoPrompt,
  };
  if (!subjective.contains(q.type)) return false;
  // The server sees labels AS the justification for a labelling question.
  final bool hasJustification =
      r.justification.trim().isNotEmpty ||
      (q.type == QType.imageLabel && r.filledLabels > 0);
  final bool carriedByAxes =
      q.type == QType.subjectiveRubric &&
      q.dims.isNotEmpty &&
      r.lines.isNotEmpty;
  return !hasJustification && !carriedByAxes;
}

Question _q(
  QType type, {
  bool requiresJustification = true,
  int dims = 0,
}) => Question(
  id: 'q1',
  genId: 'g1',
  name: 'Q',
  type: type,
  prompt: 'p',
  requiresJustification: requiresJustification,
  dims: List<QDimension>.generate(
    dims,
    (int i) => QDimension(code: 'D$i', name: 'Axis $i'),
  ),
);

Response _r({
  String justification = '',
  Map<int, String>? labels,
  List<String> lines = const <String>[],
}) => Response(
  lines: lines,
  justification: justification,
  labels: labels,
);

void main() {
  group('image_label', () {
    test('a labelled question is NOT refused', () {
      final Question q = _q(QType.imageLabel);
      final Response r = _r(labels: <int, String>{1: 'spotify icon', 2: 'clock'});

      expect(needsProse(q, r), isFalse,
          reason: 'the labels ARE the prose, server-side');
      expect(serverWouldRefuse(q, r), isFalse, reason: 'and the server agrees');
    });

    test('REGRESSION GUARD: the old rule refused exactly this answer', () {
      final Response r = _r(labels: <int, String>{1: 'spotify icon'});
      final bool oldRule = r.justification.trim().isEmpty;
      expect(oldRule, isTrue,
          reason: 'proves this fixture is the case that used to fail');
    });

    test('an UNLABELLED question is still refused, and the server agrees', () {
      final Question q = _q(QType.imageLabel);
      final Response r = _r(labels: <int, String>{1: '   ', 2: ''});

      expect(needsProse(q, r), isTrue);
      expect(serverWouldRefuse(q, r), isTrue);
    });
  });

  group('subjective_rubric', () {
    test('axes answered with a blank prose box is NOT refused', () {
      final Question q = _q(QType.subjectiveRubric, dims: 6);
      final Response r = _r(lines: const <String>['o1', 'o2']);

      expect(needsProse(q, r), isFalse, reason: 'carried_by_axes');
      expect(serverWouldRefuse(q, r), isFalse);
    });

    test('a rubric with NO dimensions is pure prose and still requires it', () {
      final Question q = _q(QType.subjectiveRubric, dims: 0);
      final Response r = _r(lines: const <String>[]);

      expect(needsProse(q, r), isTrue);
      expect(serverWouldRefuse(q, r), isTrue,
          reason: 'the server has the same carve-out, gated on dims');
    });

    test('dimensions present but none answered is still refused', () {
      final Question q = _q(QType.subjectiveRubric, dims: 6);
      final Response r = _r(lines: const <String>[]);

      expect(needsProse(q, r), isTrue);
      expect(serverWouldRefuse(q, r), isTrue);
    });
  });

  group('the prose types are unaffected', () {
    test('image_prompt and video_prompt still require written prose', () {
      for (final QType t in <QType>[QType.imagePrompt, QType.videoPrompt]) {
        expect(needsProse(_q(t), _r()), isTrue, reason: '$t blank');
        expect(serverWouldRefuse(_q(t), _r()), isTrue);

        expect(needsProse(_q(t), _r(justification: 'my answer')), isFalse);
        expect(serverWouldRefuse(_q(t), _r(justification: 'my answer')), isFalse);
      }
    });

    test('a question that does not require justification is never gated', () {
      final Question q = _q(QType.imageAb, requiresJustification: false);
      expect(needsProse(q, _r()), isFalse);
    });
  });

  group('client and server never disagree', () {
    test('the gate refuses nothing the server would accept', () {
      // THE ASSERTION THAT MATTERS MOST. A client stricter than the server is
      // exactly the bug this fixes; a client LOOSER than the server is the
      // regression the fix could introduce - the candidate would be waved
      // forward into a 422 they were never warned about.
      final List<(Question, Response, String)> cases =
          <(Question, Response, String)>[
        (_q(QType.imageLabel), _r(labels: <int, String>{1: 'a'}), 'labelled'),
        (_q(QType.imageLabel), _r(), 'label blank'),
        (_q(QType.imageLabel), _r(justification: 'typed'), 'label w/ prose'),
        (_q(QType.subjectiveRubric, dims: 3), _r(lines: const <String>['o']),
            'axes only'),
        (_q(QType.subjectiveRubric, dims: 3), _r(), 'rubric blank'),
        (_q(QType.subjectiveRubric), _r(justification: 'x'), 'rubric prose'),
        (_q(QType.imagePrompt), _r(), 'prompt blank'),
        (_q(QType.imagePrompt), _r(justification: 'x'), 'prompt written'),
        (_q(QType.videoPrompt), _r(), 'video blank'),
      ];

      for (final (Question q, Response r, String label) in cases) {
        expect(needsProse(q, r), serverWouldRefuse(q, r),
            reason: 'client and server must agree on: $label');
      }
    });
  });
}
