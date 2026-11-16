// A template's authored axes have to be ANSWERABLE by the candidate.
//
// THE DEFECT. A task template is drawn in the Form Studio editor, so an
// examiner authors real multiple-choice items - six Yes/No checks on an image
// audit. Generation flattened them to prose, and the exam runner's
// subjective_rubric branch went straight to a textarea without ever consulting
// the question's dimensions. Six distinct judgements arrived as ONE free-text
// box: the candidate could not answer them per axis, and a grader that marks
// per component had nothing per-axis to mark.
//
// Both halves are fixed - the module stores the axes as dimensions, and the
// runner renders one picker per axis - so this pins the client half against
// the real wire payload, through the real screen.
//
// The no-axes case is pinned just as hard: an ordinary rubric question, with
// no template behind it, must keep rendering exactly the textarea it always
// did.
@TestOn('vm')
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/exam/exam_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';

const String kToken = '65a12c11-fb40-48b5-af51-3f3c6822b65f';

/// The six checks from the reported generator, verbatim.
const List<String> kAxes = <String>[
  'Is the Picture Sharp and Clear?',
  'Does This Look Like a Real Image (Not AI)?',
  'Is This a Good-Looking Photo?',
  'Does the Picture Have a Watermark?',
  'Is This From the Same Photoshoot?',
  'Does This Show the Exact Same Thing in the Box?',
];

/// The wire shape the module sends for a template-authored rubric question:
/// `subjective_rubric` WITH dimensions attached.
///
/// [kind] is the Form Studio control the examiner drew. Empty is the shape
/// every question had before templates could carry a control.
List<Map<String, dynamic>> _dimensions(
  List<String> labels, {
  String kind = '',
  List<String> options = const <String>['Yes', 'No'],
}) => <Map<String, dynamic>>[
  for (int i = 0; i < labels.length; i++)
    <String, dynamic>{
      'id': 100 + i,
      'name': labels[i],
      'input_kind': kind,
      'options': <Map<String, dynamic>>[
        for (int k = 0; k < options.length; k++)
          <String, dynamic>{'id': 1000 + i * 10 + k, 'label': options[k]},
      ],
    },
];

Map<String, dynamic> _question(
  List<String> axes, {
  String kind = '',
  List<String> options = const <String>['Yes', 'No'],
}) => <String, dynamic>{
  'id': '10',
  'index': 1,
  'total': 1,
  'name': 'Task: Audit an Image Set for Photoshoot Continuity',
  'prompt': 'You are auditing an image set.',
  'question_type': 'subjective_rubric',
  'dimensions': _dimensions(axes, kind: kind, options: options),
  'images': <dynamic>[],
  'videos': <dynamic>[],
  'label_boxes': <dynamic>[],
  'answer': <String, dynamic>{
    'answered': false,
    'selected_option_ids': <dynamic>[],
    'justification': '',
    'label_answers': <String, dynamic>{},
  },
};

Map<String, dynamic> _envelope(
  List<String> axes, {
  String kind = '',
  List<String> options = const <String>['Yes', 'No'],
}) => <String, dynamic>{
  'outcome': 'question',
  'assessment': <String, dynamic>{
    'id': 21,
    'name': 'IG Entity Sample Audit',
    'state': 'in_progress',
    'duration_minutes': 45,
  },
  'attempt': <String, dynamic>{
    'id': 7,
    'state': 'in_progress',
    'is_locked': false,
    'started_at': '2026-08-11T10:00:00Z',
    'total_questions': 1,
    'answered_count': 0,
    'results_released': false,
  },
  'question': _question(axes, kind: kind, options: options),
  'answered_question_ids': <dynamic>[],
  'progress_percent': 0,
};

http.Client _server(
  List<String> axes, {
  String kind = '',
  List<String> options = const <String>['Yes', 'No'],
}) => MockClient((http.Request req) async {
  Map<String, dynamic> data = <String, dynamic>{};
  if (req.url.path.endsWith('/state')) {
    data = _envelope(axes, kind: kind, options: options);
  }
  return http.Response(
    jsonEncode(<String, dynamic>{'ok': true, 'data': data}),
    200,
    headers: <String, String>{'content-type': 'application/json'},
  );
});

AppStore _store(
  List<String> axes, {
  String kind = '',
  List<String> options = const <String>['Yes', 'No'],
}) {
  final AppStore s = AppStore(
    api: ApiClient(
      baseUrl: 'http://stub',
      client: _server(axes, kind: kind, options: options),
      bearer: 'tok',
    ),
    // THE AUTOSAVE CLOCK IS INCIDENTAL HERE - this file is about whether an
    // axis ACCEPTS an answer, not how often it writes one. But answering does
    // arm the debounce, and `testWidgets` fails a test that ends with a timer
    // still pending, so at the shipped 5s this would fail on a timer it never
    // cared about. Short values keep the same code path inside the test.
    answerDebounce: const Duration(milliseconds: 10),
    answerMaxWait: const Duration(milliseconds: 30),
  );
  s.portal = Portal.member;
  s.source = DataSource.live;
  s.meId = '2';
  s.attempts = <Attempt>[
    Attempt.fromJson(<String, dynamic>{
      'id': 7,
      'access_token': kToken,
      'assessment_id': 21,
      'state': 'in_progress',
      'started_at': '2026-08-11T10:00:00Z',
      'total_questions': 1,
    }),
  ];
  s.assessments = <Assessment>[
    Assessment.fromJson(<String, dynamic>{
      'id': 21,
      'name': 'IG Entity Sample Audit',
      'state': 'in_progress',
      'duration_minutes': 45,
    }),
  ];
  s.examByToken[kToken] = ExamView.fromJson(
    _envelope(axes, kind: kind, options: options),
  );
  return s;
}

AppStore? _lastStore;

Future<void> _open(
  WidgetTester t,
  List<String> axes, {
  String kind = '',
  List<String> options = const <String>['Yes', 'No'],
}) async {
  t.view.physicalSize = const Size(1400, 3000);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  final AppStore store = _store(axes, kind: kind, options: options);
  _lastStore = store;
  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: AssessmentNavScope(
        nav: AssessmentNav(),
        child: ExamScreen(
          store: store,
          token: kToken,
          sub: ExamSub.question,
          questionNumber: 1,
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
}

void main() {
  testWidgets('six authored axes become six answerable pickers', (
    WidgetTester t,
  ) async {
    await _open(t, kAxes);

    for (final String label in kAxes) {
      expect(
        find.text(label.toUpperCase()),
        findsOneWidget,
        reason:
            'every authored axis must be answerable on its own - before the '
            'fix all six collapsed into a single free-text box',
      );
    }
    expect(find.text('Yes'), findsNWidgets(kAxes.length));
    expect(find.text('No'), findsNWidgets(kAxes.length));
  });

  testWidgets('a question with axes still asks for reasoning', (
    WidgetTester t,
  ) async {
    await _open(t, <String>[kAxes.first]);

    expect(
      find.text('YOUR REASONING'),
      findsOneWidget,
      reason: 'a template that wants a reason on a "No" must still collect it',
    );
  });

  testWidgets('a 1-5 rating renders as a scale, not five stacked radios', (
    WidgetTester t,
  ) async {
    // Q7R's grading question is a 1-5 scale. Every axis used to render as a
    // stack of full-width radio rows, so a five-point scale read as five
    // separate questions and pushed the rest of the task off-screen.
    await _open(
      t,
      <String>['Rate this critique'],
      kind: 'linearScale',
      options: <String>['1', '2', '3', '4', '5'],
    );

    expect(find.text('RATE THIS CRITIQUE'), findsOneWidget);
    for (final String point in <String>['1', '2', '3', '4', '5']) {
      expect(
        find.text(point),
        findsOneWidget,
        reason: 'every point of the authored scale must be pickable',
      );
    }
    expect(
      find.byKey(const Key('axis-scale')),
      findsOneWidget,
      reason: 'a scale is ONE question with five points, drawn as one row',
    );
  });

  testWidgets('a checkboxes axis accepts more than one answer', (
    WidgetTester t,
  ) async {
    // A checkboxes item asks "tick every one that applies". Rendering it as
    // radios silently discarded every pick but the last.
    await _open(
      t,
      <String>['Which problems apply?'],
      kind: 'checkboxes',
      options: <String>['Blurry', 'Watermarked', 'Wrong entity'],
    );

    await t.tap(find.text('Blurry'));
    await t.pumpAndSettle();
    await t.tap(find.text('Watermarked'));
    await t.pumpAndSettle();
    // Picking an option schedules the debounced autosave; let it fire so the
    // tree is torn down with no pending timer.
    await t.pump(const Duration(seconds: 2));

    // BOTH picks must survive. As radios the second tap replaced the first,
    // so a candidate ticking three problems reported only the last one.
    final AppStore store = _lastStore!;
    final ExamView view = store.examByToken[kToken]!;
    final Response saved = store.responseFor(
      store.attempts.first,
      view.question!,
    );
    expect(
      saved.lines.length,
      2,
      reason: 'a checkboxes axis keeps every pick; radios kept only the last',
    );
  });

  testWidgets('an axis with NO authored kind keeps the old radio stack', (
    WidgetTester t,
  ) async {
    // Every question written before templates carried a control sends no
    // input_kind. Those must render exactly as they always did.
    await _open(t, <String>[kAxes.first]);

    expect(find.text('Yes'), findsOneWidget);
    expect(find.text('No'), findsOneWidget);
    expect(
      find.byKey(const Key('axis-scale')),
      findsNothing,
      reason: 'no authored kind means the old stacked radios, unchanged',
    );
  });

  testWidgets('a rubric question with NO axes is the old textarea, unchanged', (
    WidgetTester t,
  ) async {
    await _open(t, const <String>[]);

    expect(find.text('YOUR ANSWER'), findsOneWidget);
    expect(
      find.text('Write your answer here.'),
      findsNothing,
      reason: 'candidate answer boxes carry no hint text (owner, 2026-09-29)',
    );
  });
}
