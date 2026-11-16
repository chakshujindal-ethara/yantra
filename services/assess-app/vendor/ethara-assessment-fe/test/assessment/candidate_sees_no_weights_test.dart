@TestOn('vm')
// Reads the SOURCE TREE through dart:io for the first group, so it can only run
// on the VM - same harness limit as live_payload_test.dart.
//
// THE SCORING MACHINERY IS AN ADMIN FACT, NOT A CANDIDATE ONE.
//
// The admin surfaces print the lane weights deliberately: "Verdicts weight
// 0.75", "Key closeness weight 0.60", the blended raw and the threshold beside
// it. A mark nobody can check is a mark nobody can defend, and the admin is the
// person who has to defend it to the candidate.
//
// The candidate's own results sheet is the opposite case, and for a reason that
// is not squeamishness. A candidate told their justification "is weighted 25%"
// has been handed the shape of the paper rather than feedback on their work -
// the lesson is to spend the effort where the weight is, which is the one thing
// an assessment must not teach. They get the verdict, what they got right, what
// they lost and how to fix it. Not the arithmetic behind it.
//
// This is asserted two ways, because either alone is escapable: by SOURCE, so a
// weight literal cannot be pasted into a candidate screen, and by MODEL, so the
// numbers cannot arrive through the payload instead.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/domain/models.dart';

/// The screen folders a CANDIDATE reaches. `admin/` is deliberately absent.
///
/// `widgets/` is in scope because the answer sheet paints from the shared
/// widgets too: a weight literal pasted into one of those reaches the candidate
/// just as surely, and a scan of `screens/` alone never sees it.
const List<String> _candidateDirs = <String>[
  'lib/assessment/screens/exam',
  'lib/assessment/screens/member',
  'lib/assessment/screens/account',
  'lib/assessment/widgets',
];

/// Written as patterns rather than bare numbers on purpose: `0.75` also matches
/// an opacity, a flex factor and a duration, and a test that fails on those
/// gets deleted rather than fixed.
final Map<String, RegExp> _forbidden = <String, RegExp>{
  'a named weight': RegExp(r'weight[s]?\s*[:=]?\s*0?\.\d', caseSensitive: false),
  'a percentage weighting claim': RegExp(
    r'(scored|weighted|counts?|worth)\s+(at\s+)?\d{1,3}\s*%',
    caseSensitive: false,
  ),
  'the key-closeness lane': RegExp('key closeness', caseSensitive: false),
  'the SOP-coverage lane': RegExp('sop coverage', caseSensitive: false),
  'the blended-raw lane': RegExp('blended raw', caseSensitive: false),
};

List<File> _dartFilesIn(String dir) {
  final Directory d = Directory(dir);
  if (!d.existsSync()) return const <File>[];
  return d
      .listSync(recursive: true)
      .whereType<File>()
      .where((File f) => f.path.endsWith('.dart'))
      .toList();
}

void main() {
  group('no candidate screen names the scoring machinery', () {
    test('the candidate screen folders exist and were actually scanned', () {
      // The failure this guards: a folder rename turns every check below into
      // a loop over nothing, and the suite reports green while guarding air.
      for (final String dir in _candidateDirs) {
        expect(
          _dartFilesIn(dir),
          isNotEmpty,
          reason: '$dir holds no Dart files - has the tree moved?',
        );
      }
    });

    test('no weight, lane name or percentage claim appears in one', () {
      final List<String> hits = <String>[];
      for (final String dir in _candidateDirs) {
        for (final File f in _dartFilesIn(dir)) {
          final List<String> lines = f.readAsLinesSync();
          for (int i = 0; i < lines.length; i++) {
            final String line = lines[i];
            // Comments are the engineering record - they SHOULD explain why the
            // weighting is withheld, and one that quotes the old "25%" copy is
            // documentation, not a leak. Only rendered text is in scope.
            if (line.trimLeft().startsWith('//')) continue;
            _forbidden.forEach((String what, RegExp pattern) {
              if (pattern.hasMatch(line)) {
                hits.add('${f.path}:${i + 1} names $what -> ${line.trim()}');
              }
            });
          }
        }
      }
      expect(
        hits,
        isEmpty,
        reason:
            'a candidate-facing screen states how the platform weighs the '
            'score:\n${hits.join('\n')}\n'
            'These belong on the admin surfaces, where the weights are printed '
            'so a mark can be checked and defended.',
      );
    });

    test('the patterns catch the copy that was actually there', () {
      // THE CONTROL THAT MATTERS. A regex that matches nothing passes the check
      // above on any codebase, forever, and reads as a guarantee. These are the
      // real strings this rule exists to keep off a candidate screen - the
      // first is the exam justification placeholder verbatim, as it shipped.
      const Map<String, String> knownBad = <String, String>{
        'a percentage weighting claim':
            "'Explain the call you made. Scored at 25% alongside the verdict.'",
        'a named weight': "note: 'weight 0.75',",
        'the key-closeness lane': "_Meter(label: 'Key closeness', …)",
        'the SOP-coverage lane': "_Meter(label: 'SOP coverage', …)",
        'the blended-raw lane': "_Meter(label: 'Blended raw', …)",
      };
      knownBad.forEach((String what, String line) {
        expect(
          _forbidden[what]!.hasMatch(line),
          isTrue,
          reason: 'the $what pattern no longer matches $line',
        );
      });
    });

    test('and do NOT fire on ordinary Flutter code', () {
      // The other half: a rule that flags `FontWeight.w600` or a 0.75 opacity
      // gets switched off by the next person, and then guards nothing.
      for (final String benign in <String>[
        'fontWeight: FontWeight.w600,',
        'color: t.textMuted.withValues(alpha: 0.75),',
        'const Duration(milliseconds: 250)',
        'flex: 3,',
        'width: 100%',
      ]) {
        for (final MapEntry<String, RegExp> e in _forbidden.entries) {
          expect(
            e.value.hasMatch(benign),
            isFalse,
            reason: '${e.key} falsely flags $benign',
          );
        }
      }
    });

    test('the admin screens DO name them, so the rule is a boundary', () {
      // The positive control. Without it, the check above would pass just as
      // well on a codebase that had lost the admin breakdown entirely - and
      // "nobody can see the weights" is a different, worse outcome than the one
      // being enforced here.
      final String adminSource = _dartFilesIn('lib/assessment/screens/admin')
          .map((File f) => f.readAsStringSync())
          .join('\n');
      expect(
        _forbidden['a named weight']!.hasMatch(adminSource),
        isTrue,
        reason:
            'the admin audit no longer prints any weight - an admin cannot '
            'check a mark they cannot see the arithmetic for',
      );
    });
  });

  group('the candidate answer sheet drops the machinery from the payload', () {
    /// A released review row with EVERY internal the server could ever put on
    /// it, including the ones it does not send today. Populated, not blank: a
    /// row with nothing to leak passes a leak test for the wrong reason.
    Map<String, dynamic> wireRow() => <String, dynamic>{
      'index': 1,
      'question_id': 21,
      'name': 'Which render is better',
      'prompt': 'Compare the two renders.',
      'question_type': 'image_ab',
      'chosen': <String>['Response A'],
      'correct': <String>['Response B'],
      'justification': 'A looked cleaner to me.',
      'verdict': 'Failed',
      'kind': 'fail',
      'feedback': 'You named the sofa precisely. Next time say why.',
      'credit': <String>['Named the deciding object'],
      'deductions': <String>['Did not say why it decided the call'],
      // The server DOES send this one, and the client has never carried it.
      'score_raw': 0.615,
      // These the server withholds; asserted anyway, because the way this
      // regresses is somebody widening the serializer to "show more detail".
      'llm_raw_100': 61.5,
      'key_closeness': 60.0,
      'sop_coverage': 25.0,
      'clarity': 'mixed',
      'reasoning': 'blend: 0.75*verdict + 0.25*justification = 61.5',
      'subscores': <String, dynamic>{
        'ab_verdict_pct': 66.6,
        'ab_justification_pct': 82.0,
        'ab_final_pct': 61.5,
      },
      'final_mark': 0.0,
      'mcq_mark': 0.0,
      'pass_threshold': 70.0,
    };

    test('a released row keeps the coaching and nothing numeric', () {
      final AnswerSheetRow row = AnswerSheetRow.fromJson(
        wireRow(),
        released: true,
      );

      // What the candidate is owed, and does get.
      expect(row.verdict, 'Failed');
      expect(row.feedback, isNotEmpty);
      expect(row.credit, isNotEmpty);
      expect(row.deductions, isNotEmpty);
      expect(row.correct, <String>['Response B']);

      // And what they are not. Rendered through the same string the widget
      // builds from, so a field added to the model shows up here whatever it
      // is called.
      final String rendered = <String>[
        row.verdict,
        row.feedback,
        ...row.credit,
        ...row.deductions,
        ...row.correct,
        ...row.chosen,
        row.justification,
      ].join(' ').toLowerCase();

      for (final String term in <String>[
        '0.75',
        '0.25',
        '0.60',
        '61.5',
        '0.615',
        'key closeness',
        'sop coverage',
        'weight',
        'threshold',
      ]) {
        expect(
          rendered,
          isNot(contains(term)),
          reason: 'the candidate answer sheet surfaced "$term"',
        );
      }
    });

    test('before release it withholds the outcome as well', () {
      final AnswerSheetRow row = AnswerSheetRow.fromJson(
        wireRow(),
        released: false,
      );

      expect(row.verdict, isEmpty);
      expect(row.feedback, isEmpty);
      expect(row.credit, isEmpty);
      expect(row.deductions, isEmpty);
      expect(row.correct, isEmpty);
      // The candidate's own words stay theirs, released or not.
      expect(row.justification, 'A looked cleaner to me.');
    });
  });
}
