// A grid the examiner drew has to reach the candidate AS A GRID.
//
// THE DEFECT, seen in a real browser on 2026-09-01. The server turns a
// `choiceGrid`/`checkboxGrid` into one dimension per ROW - name = the row label,
// options = the columns - which is the right storage shape, because each row is
// independently keyed and independently scored. But the exam runner rendered
// that shape row by row: a stack of separate option lists with the column
// labels repeated under every single row. Form Studio's own Preview drew a
// proper matrix at the same moment, so the examiner authored a grid, previewed
// a grid, and the candidate answered something that did not look like one.
//
// Scoring was never wrong - which is exactly why this survived. It is a
// fidelity defect, and the only way to catch it is to assert on the SHAPE the
// candidate sees.
//
// WHAT EACH TEST WOULD DO ON REVERT is stated per test. Reverting means
// deleting the `_isGrid` branch in `_Options.build`, so every axis falls back to
// the stacked `_Option` rows.
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

/// The rows of a real triage grid, from the Customer Support QA bank.
const List<String> kRows = <String>[
  'Refund asked 12h after purchase',
  'Package lost, P.O. box address',
  'Damage reported, no photo',
];

/// Its columns. Note two of the three share no words, so a label assertion
/// cannot pass by accident on a row label.
const List<String> kCols = <String>[
  'Issue refund',
  'Deny claim',
  'Request more info',
];

List<Map<String, dynamic>> _dimensions(
  List<String> rows, {
  required String kind,
  required List<String> columns,
  bool ragged = false,
}) => <Map<String, dynamic>>[
  for (int i = 0; i < rows.length; i++)
    <String, dynamic>{
      'id': 100 + i,
      'name': rows[i],
      'input_kind': kind,
      'options': <Map<String, dynamic>>[
        // `ragged` drops a column from every row after the first, which is the
        // one shape a matrix cannot honestly draw - see the test that uses it.
        for (
          int k = 0;
          k < (ragged && i > 0 ? columns.length - 1 : columns.length);
          k++
        )
          <String, dynamic>{'id': 1000 + i * 10 + k, 'label': columns[k]},
      ],
    },
];

Map<String, dynamic> _envelope(
  List<String> rows, {
  required String kind,
  required String questionType,
  List<String> columns = kCols,
  bool ragged = false,
}) => <String, dynamic>{
  'outcome': 'question',
  'assessment': <String, dynamic>{
    'id': 21,
    'name': 'Customer Support QA Certification',
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
  'question': <String, dynamic>{
    'id': '10',
    'index': 1,
    'total': 1,
    'name': 'For each scenario, choose the correct action.',
    'prompt': 'For each scenario, choose the correct action.',
    'question_type': questionType,
    'dimensions': _dimensions(
      rows,
      kind: kind,
      columns: columns,
      ragged: ragged,
    ),
    'images': <dynamic>[],
    'videos': <dynamic>[],
    'label_boxes': <dynamic>[],
    'answer': <String, dynamic>{
      'answered': false,
      'selected_option_ids': <dynamic>[],
      'justification': '',
      'label_answers': <String, dynamic>{},
    },
  },
  'answered_question_ids': <dynamic>[],
  'progress_percent': 0,
};

AppStore _store(
  List<String> rows, {
  required String kind,
  required String questionType,
  List<String> columns = kCols,
  bool ragged = false,
}) {
  final Map<String, dynamic> env = _envelope(
    rows,
    kind: kind,
    questionType: questionType,
    columns: columns,
    ragged: ragged,
  );
  final AppStore s = AppStore(
    api: ApiClient(
      baseUrl: 'http://stub',
      client: MockClient(
        (http.Request req) async => http.Response(
          jsonEncode(<String, dynamic>{
            'ok': true,
            'data': req.url.path.endsWith('/state') ? env : <String, dynamic>{},
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        ),
      ),
      bearer: 'tok',
    ),
    // THE AUTOSAVE CLOCK IS INCIDENTAL HERE - this file is about how a control
    // RENDERS, not how often it writes. But tapping one does arm the debounce,
    // and `testWidgets` fails a test that ends with a timer still pending, so
    // at the shipped 5s every tap test would fail on a timer it never cared
    // about. Short values keep the same code path inside the test's lifetime.
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
      'name': 'Customer Support QA Certification',
      'state': 'in_progress',
      'duration_minutes': 45,
    }),
  ];
  s.examByToken[kToken] = ExamView.fromJson(env);
  return s;
}

Future<AppStore> _open(
  WidgetTester t,
  List<String> rows, {
  required String kind,
  String questionType = 'mcq',
  List<String> columns = kCols,
  bool ragged = false,
}) async {
  t.view.physicalSize = const Size(1400, 3000);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  final AppStore store = _store(
    rows,
    kind: kind,
    questionType: questionType,
    columns: columns,
    ragged: ragged,
  );
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
  return store;
}

void main() {
  testWidgets('a choiceGrid draws each column header ONCE, not per row', (
    WidgetTester t,
  ) async {
    await _open(t, kRows, kind: 'choiceGrid');

    // THE DISCRIMINATOR. Three rows x three columns rendered as stacked option
    // lists repeats every column label three times. A matrix names each column
    // once, in the header, and the rows carry only their own labels. Reverting
    // the branch makes each of these findsNWidgets(3), so this fails.
    for (final String col in kCols) {
      expect(
        find.text(col),
        findsOneWidget,
        reason:
            '"$col" is a column header and belongs on screen exactly once; '
            'finding it ${kRows.length} times means the grid was flattened '
            'back into one option list per row.',
      );
    }

    // Every row label still present - a matrix must not lose the thing that
    // says which scenario the candidate is judging.
    for (final String row in kRows) {
      expect(find.text(row), findsOneWidget, reason: 'row "$row" is missing');
    }
  });

  testWidgets('a choiceGrid renders the matrix widget, not stacked options', (
    WidgetTester t,
  ) async {
    await _open(t, kRows, kind: 'choiceGrid');
    // The keyed handle exists because the matrix widget is private to
    // answer_layouts.dart, exactly as `axis-scale` is for the scale row.
    // Absent on revert.
    expect(find.byKey(const Key('axis-grid')), findsOneWidget);
  });

  testWidgets('every intersection is tappable and writes that row only', (
    WidgetTester t,
  ) async {
    final AppStore store = await _open(t, kRows, kind: 'choiceGrid');
    expect(find.byKey(const Key('axis-grid')), findsOneWidget);

    // 3 rows x 3 columns = 9 cells. On revert there is no matrix at all, so
    // this count is 0 and the test fails before the tap.
    final Finder cells = find.descendant(
      of: find.byKey(const Key('axis-grid')),
      matching: find.byType(GestureDetector),
    );
    expect(cells, findsNWidgets(kRows.length * kCols.length));

    // Tap the first row's second column, then assert exactly one line was
    // written. A single-select grid row must not accumulate.
    await t.tap(cells.at(1));
    await t.pumpAndSettle();
    // Let the debounced autosave fire so the tree tears down with no pending
    // timer.
    await t.pump(const Duration(seconds: 2));

    final ExamView view = store.examByToken[kToken]!;
    final Response saved = store.responseFor(
      store.attempts.first,
      view.question!,
    );
    expect(
      saved.lines.length,
      1,
      reason: 'one tap on a single-select row is one selection',
    );
    expect(
      saved.lines.first,
      '1001',
      reason:
          'row 0 / column 1 is option id 1001 - a cell must write its '
          'OWN row, not a neighbour',
    );
  });

  testWidgets('a checkboxGrid row accepts more than one column', (
    WidgetTester t,
  ) async {
    final AppStore store = await _open(
      t,
      kRows,
      kind: 'checkboxGrid',
      questionType: 'msq',
    );
    final Finder cells = find.descendant(
      of: find.byKey(const Key('axis-grid')),
      matching: find.byType(GestureDetector),
    );
    await t.tap(cells.at(0));
    await t.pumpAndSettle();
    await t.tap(cells.at(1));
    await t.pumpAndSettle();
    await t.pump(const Duration(seconds: 2));

    // Two picks on ONE row survive together. A single-select grid would have
    // replaced the first with the second, so this pins the multi behaviour
    // rather than re-testing the shape.
    final ExamView view = store.examByToken[kToken]!;
    final Response saved = store.responseFor(
      store.attempts.first,
      view.question!,
    );
    expect(saved.lines.length, 2);
    expect(saved.lines.toSet(), <String>{'1000', '1001'});
  });

  testWidgets('an axis with NO authored kind keeps the stacked rows', (
    WidgetTester t,
  ) async {
    // Every question written before templates carried a control has an empty
    // `input_kind`. Those must render exactly as they always did - this is the
    // regression guard on the fix itself, and it passes both before and after
    // by design.
    await _open(t, kRows, kind: '');
    expect(find.byKey(const Key('axis-grid')), findsNothing);
    // Flattened: each column label appears once per row.
    expect(find.text(kCols.first), findsNWidgets(kRows.length));
  });

  testWidgets('rows with DIFFERENT columns fall back rather than guess', (
    WidgetTester t,
  ) async {
    // A matrix has one set of column headers by definition. If the rows
    // disagree there is no honest header to draw, and inventing one would put a
    // control under the wrong column - a wrong answer the candidate cannot see.
    // So the fallback is deliberate, and this asserts it.
    await _open(t, kRows, kind: 'choiceGrid', ragged: true);
    expect(
      find.byKey(const Key('axis-grid')),
      findsNothing,
      reason: 'ragged rows must not be drawn as a matrix',
    );
    // The fallback prints each axis name as an UPPERCASE eyebrow heading -
    // that is the long-standing stacked-rows presentation, and asserting the
    // as-authored casing here would be testing the matrix's own styling
    // instead of the fallback's.
    for (final String row in kRows) {
      expect(
        find.text(row.toUpperCase()),
        findsOneWidget,
        reason: 'the fallback still has to name every row, and be answerable',
      );
    }
  });
}
