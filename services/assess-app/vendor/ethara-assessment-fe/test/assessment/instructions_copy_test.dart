// The instructions page has to tell a candidate what NOT to do.
//
// It used to print `ProctorRule.hint` - operator copy from the config switch,
// third person, about the system: "Leaving the exam tab is recorded as a
// violation.", "The candidate name and email are tiled across the exam
// surface." Seven of those under a heading reading "What Is Monitored"
// described the observer rather than instructing the observed, and candidates
// finished the page still not knowing that switching tabs would end their
// sitting. `candidateRule` is the imperative half of that split; `hint` stays
// as it was, because the two admin surfaces read it.
//
// Pinned here: the voice (imperative, second person, short), the
// prohibition/hold split that picks the glyph, and - the one that costs a
// candidate their paper if it regresses - that the page's promise about ending
// the exam follows `violationAction` in BOTH directions.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/exam/exam_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/assessment/widgets/feedback.dart';

const String _token = '65a12c11-fb40-48b5-af51-3f3c6822b65f';

/// `/exam/<token>/state` at outcome `instructions`, with the violation policy
/// the case under test needs.
///
/// The nesting matters twice over, and both halves are load-bearing. `rules`
/// goes INSIDE the assessment object, because `Assessment.fromJson` reads
/// `jobj(j, 'rules')` off the assessment it is handed. But `max_violations` and
/// `violation_action` are read from the assessment's OWN level, so the server
/// hoists them out of the rules block as well (`serializers.py:663-669`,
/// which records that leaving them nested made the client fall back to its own
/// log-only defaults over whatever the operator had configured). A fixture that
/// nests them only would silently test log-only twice.
http.Client _server(String action) => MockClient((http.Request req) async {
  final Map<String, dynamic> asm = <String, dynamic>{
    'id': 21,
    'name': 'Forklift Safety - Induction',
    'state': 'in_progress',
    'duration_minutes': 30,
    'max_violations': 3,
    'violation_action': action,
    'rules': <String, dynamic>{
      'tab_switch': true,
      'copy_paste': true,
      'right_click': false,
      'devtools': false,
      'fullscreen': true,
      'webcam': false,
      'watermark': false,
      'watermark_label': '',
      'max_violations': 3,
      'violation_action': action,
      'violation_count': 0,
    },
  };
  return http.Response(
    jsonEncode(<String, dynamic>{
      'ok': true,
      'data': <String, dynamic>{
        'outcome': 'instructions',
        'assessment': asm,
        'attempt': <String, dynamic>{
          'id': 7,
          'token': _token,
          'assessment_id': 21,
          'state': 'pending',
          'is_locked': false,
          'started_at': null,
          'deadline': null,
          'submitted_at': null,
          'total_questions': 3,
          'answered_count': 0,
          'results_released': false,
        },
        'rules': asm['rules'],
        'preview': false,
        'instructions': <String, dynamic>{
          'duration_minutes': 30,
          'total_questions': 3,
          'question_limit': 3,
        },
      },
    }),
    200,
    headers: <String, String>{'content-type': 'application/json'},
  );
});

/// Mounts the real instructions page for one violation policy.
Future<void> _mount(WidgetTester t, String action) async {
  t.view.physicalSize = const Size(1400, 2600);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);

  final AppStore s =
      AppStore(
          api: ApiClient(
            baseUrl: 'http://stub',
            client: _server(action),
            bearer: 'stub',
          ),
        )
        ..portal = Portal.member
        ..source = DataSource.live
        ..meId = '2'
        ..meName = 'Utkarsh Jain E'
        ..meEmail = 'utkarsh@example.com';

  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: AssessmentNavScope(
        nav: AssessmentNav(),
        child: ExamScreen(store: s, token: _token, sub: ExamSub.instructions),
      ),
    ),
  );
  await t.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  await t.pumpAndSettle();
}

List<String> _text(WidgetTester t) => t
    .widgetList<Text>(find.byType(Text))
    .map((Text w) => w.data ?? w.textSpan?.toPlainText() ?? '')
    .where((String s) => s.isNotEmpty)
    .toList();

void main() {
  group('candidateRule', () {
    test('every rule is one short imperative line', () {
      for (final ProctorRule r in ProctorRule.values) {
        final String text = r.candidateRule.text;
        expect(text, isNotEmpty, reason: '${r.name} has no candidate copy');
        expect(
          text.endsWith('.'),
          isTrue,
          reason: '${r.name}: a rule is a sentence - "$text"',
        );
        // `seb` is exempt: a footnote, not a rule in the list, and its copy
        // was fixed with the feature (ETP plans Part 11).
        if (r != ProctorRule.seb) {
          expect(
            text.split(' ').length,
            lessThanOrEqualTo(8),
            reason:
                '${r.name}: a rule a candidate SKIMS has to fit one line - '
                '"$text"',
          );
        }
        // The operator wording is what this exists to escape. If they ever
        // converge, the split has been undone.
        expect(
          text,
          isNot(equals(r.hint)),
          reason: '${r.name} is printing operator copy at a candidate again',
        );
      }
    });

    test('the four avoidable acts are phrased as prohibitions', () {
      const List<ProctorRule> acts = <ProctorRule>[
        ProctorRule.tabSwitch,
        ProctorRule.copyPaste,
        ProctorRule.rightClick,
        ProctorRule.devtools,
      ];
      for (final ProctorRule r in acts) {
        expect(
          r.candidateRule.text,
          startsWith('Do not'),
          reason: '${r.name} is an act to avoid, so it says so',
        );
        expect(r.candidateRule.prohibition, isTrue);
      }
    });

    test('the two states to HOLD are not phrased as double negatives', () {
      // "Do not leave fullscreen" negates the thing being asked for. These
      // keep the imperative mood without the negation, and take a check rather
      // than the deny mark.
      for (final ProctorRule r in <ProctorRule>[
        ProctorRule.fullscreen,
        ProctorRule.webcam,
      ]) {
        expect(r.candidateRule.text, isNot(startsWith('Do not')));
        expect(r.candidateRule.prohibition, isFalse);
      }
      expect(ProctorRule.fullscreen.candidateRule.text, 'Stay in fullscreen.');
      expect(ProctorRule.webcam.candidateRule.text, 'Keep your camera on.');
    });

    test('watermark and seb are the only rules that are not instructions', () {
      // Nothing for a candidate to do about either, and nothing they can cost
      // them: `firesViolation` is false for these two alone (SEB is enforced
      // by the server, before any question is served). The page keeps them
      // out of the rule list for that reason, so every deny mark there means
      // the same thing.
      expect(
        ProctorRule.values.where((ProctorRule r) => !r.firesViolation),
        <ProctorRule>[ProctorRule.watermark, ProctorRule.seb],
      );
      expect(ProctorRule.seb.candidateRule.prohibition, isFalse);
      expect(ProctorRule.watermark.candidateRule.prohibition, isFalse);
      expect(
        ProctorRule.watermark.candidateRule.text,
        isNot(startsWith('Do not')),
      );
    });

    test('right-click and paste are prohibitions because they DO fire', () {
      // Both read as merely blocked ("Copy and paste is disabled.") and both
      // call `preventDefault()` AND `_fire()` in `proctor_web.dart`, so under
      // auto-submit with a cap of 1 either one ends the exam. Telling a
      // candidate they are only inconvenient is the understatement that costs
      // them the paper.
      expect(ProctorRule.copyPaste.firesViolation, isTrue);
      expect(ProctorRule.rightClick.firesViolation, isTrue);
      expect(ProctorRule.copyPaste.candidateRule.prohibition, isTrue);
      expect(ProctorRule.rightClick.candidateRule.prohibition, isTrue);
    });
  });

  group('the page-level promise follows violationAction', () {
    // What `_Instructions` computes as `ends`, and what the header sub-line and
    // the tick label are chosen by. Stated as the bare expression because the
    // bug worth pinning is arithmetic: it was `cap > 0 || isAuto` under a `cap`
    // normalised to a minimum of 1, so it was ALWAYS true - which under Log
    // only promises an auto-submit that never comes.
    bool ends(ViolationAction a) => a.isAuto;

    test('Log only never promises the exam can end', () {
      expect(ends(ViolationAction.logOnly), isFalse);
      expect(
        violationConsequence(ViolationAction.logOnly, 1).strong,
        contains('never ended automatically'),
        reason: 'and the Notice under it must agree with the sub-line',
      );
    });

    test('Auto-submit does promise it, cap or no cap', () {
      expect(ends(ViolationAction.autoSubmit), isTrue);
      for (final int cap in <int>[0, 1, 3, 20]) {
        expect(
          violationConsequence(ViolationAction.autoSubmit, cap).strong,
          contains('auto-submits'),
        );
      }
    });
  });

  group('the consequence Notice', () {
    // THE ASSERTION THAT CATCHES THE WRONG FIX. "The exam is never ended
    // automatically." was asked to come off this page. It is not a literal
    // here - it is `violationConsequence`'s `!isAuto` branch, shared with
    // `assessment_detail_screen.dart` and `new_assessment_screen.dart` and
    // pinned by `violation_notice_test.dart`. So the page suppresses the
    // Notice instead of rewording the function. Someone "simplifying" that by
    // editing `enums.dart` breaks those two suites; someone deleting the
    // `if (ends)` guard breaks this one.
    testWidgets('is absent under Log only', (WidgetTester t) async {
      await _mount(t, 'log_only');

      expect(find.textContaining('Follow these rules'), findsOneWidget);
      expect(
        find.byType(Notice),
        findsNothing,
        reason:
            'the sub-line and the tick label each state that violations are '
            'recorded - the Notice was a third statement of it',
      );
      expect(_text(t).where((String s) => s.contains('never ended')), isEmpty);
    });

    testWidgets('is present under Auto-submit', (WidgetTester t) async {
      await _mount(t, 'auto_submit');

      // The suppression is conditional, not a deletion. A candidate whose exam
      // CAN end has to be told so before they start it.
      expect(find.byType(Notice), findsOneWidget);
      expect(
        _text(t).where((String s) => s.contains('auto-submits')),
        isNotEmpty,
      );
      // Spoken TO the candidate, plural-correct - not the admin's third
      // person "Candidates get 2 warned violation(s) first."
      expect(
        _text(
          t,
        ).where((String s) => s.contains('You get 2 warned violations first.')),
        isNotEmpty,
      );
      expect(
        _text(
          t,
        ).where((String s) => s.contains('Candidates') || s.contains('(s)')),
        isEmpty,
      );
    });

    testWidgets('the identity line names the candidate, once', (
      WidgetTester t,
    ) async {
      await _mount(t, 'log_only');

      // Both halves on one line, joined by the ASCII separator. The old page
      // interpolated `personById`, which is null for every candidate, and so
      // said "the invited candidate" instead.
      expect(
        find.text('Utkarsh Jain E  -  utkarsh@example.com'),
        findsOneWidget,
      );
      expect(
        _text(t).where((String s) => s.contains('the invited candidate')),
        isEmpty,
        reason: 'there IS a name on the page, so the fallback must not fire',
      );
      // The two cut sentences.
      expect(
        _text(t).where((String s) => s.contains('clock does not')),
        isEmpty,
      );
      expect(
        _text(t).where((String s) => s.contains('No video is recorded')),
        isEmpty,
      );
    });
  });
}
