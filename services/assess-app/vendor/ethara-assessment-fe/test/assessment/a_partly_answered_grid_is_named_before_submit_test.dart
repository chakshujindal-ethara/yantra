// A grid ticked on one row of three counted as answered.
//
// The server calls a question answered once it holds any selection, so the
// review said "Every question has an answer." over a 3-row grid with 2 rows
// blank, and Submit went straight through. The review now counts the blank
// rows of a multi-row question and names them in the "Submit Anyway" sheet:
// from the server's `rows_unanswered` when the review carries it (which
// survives a reload), else from the rows of the questions this session
// answered. Partly answered has its own colour and legend entry, and the top
// bar and the panel count "answered" the same way (whole or partial).
// Autosave of the partial answer is unchanged.
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

const String kToken = 'tok-grid';

Map<String, dynamic> _row(String id, String name) => <String, dynamic>{
  'id': id,
  'name': name,
  'input_kind': 'choiceGrid',
  'options': <dynamic>[
    <String, dynamic>{'id': '${id}y', 'label': 'Yes'},
    <String, dynamic>{'id': '${id}n', 'label': 'No'},
  ],
};

bool _said(WidgetTester t, String line) => t
    .widgetList<RichText>(find.byType(RichText))
    .any((RichText r) => r.text.toPlainText().contains(line));

/// A live sitting with Q3 - a 3-row grid - on screen. [posts] records every
/// request's last path segment.
AppStore _store(List<String> posts) {
  final AppStore s = AppStore(
    api: ApiClient(
      baseUrl: 'http://stub',
      bearer: 't',
      client: MockClient((http.Request req) async {
        posts.add(req.url.path.split('/').last);
        return http.Response(
          jsonEncode(<String, dynamic>{
            'ok': true,
            'data': <String, dynamic>{},
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }),
    ),
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
      'started_at': DateTime.now().toUtc().toIso8601String(),
      'deadline': DateTime.now()
          .add(const Duration(hours: 1))
          .toUtc()
          .toIso8601String(),
    }),
  ];
  s.assessments = <Assessment>[
    Assessment.fromJson(<String, dynamic>{
      'id': 21,
      'name': 'sample test',
      'state': 'in_progress',
      'duration_minutes': 60,
    }),
  ];
  s.examByToken[kToken] = ExamView.fromJson(<String, dynamic>{
    'outcome': 'question',
    'question': <String, dynamic>{
      'id': '30',
      'index': 3,
      'total': 3,
      'name': 'Question 3',
      'prompt': 'Prompt.',
      'question_type': 'mcq',
      'dimensions': <dynamic>[
        _row('r1', 'Refund'),
        _row('r2', 'Exchange'),
        _row('r3', 'Repair'),
      ],
      'images': <dynamic>[],
      'videos': <dynamic>[],
      'label_boxes': <dynamic>[],
    },
    'answered_question_ids': <dynamic>[],
    'progress_percent': 0,
  });
  return s;
}

/// The server's checklist: all three "answered"; [rowsUnanswered] on Q3.
void _review(AppStore s, {int? rowsUnanswered}) {
  s.examReviewByToken[kToken] = <ExamReviewRow>[
    for (final (int i, String id) in <(int, String)>[
      (1, '10'),
      (2, '20'),
      (3, '30'),
    ])
      ExamReviewRow.fromJson(<String, dynamic>{
        'index': i,
        'question_id': id,
        'name': 'Q$i',
        'answered': true,
        if (id == '30' && rowsUnanswered != null)
          'rows_unanswered': rowsUnanswered,
      }),
  ];
}

Future<void> _mount(WidgetTester t, AppStore s) async {
  t.view.physicalSize = const Size(1400, 2400);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: AssessmentNavScope(
        nav: AssessmentNav(),
        child: ExamScreen(store: s, token: kToken, sub: ExamSub.review),
      ),
    ),
  );
  await t.pump();
}

void main() {
  testWidgets('one row of a 3-row grid is partly answered, and named', (
    WidgetTester t,
  ) async {
    final List<String> posts = <String>[];
    final AppStore s = _store(posts);

    // The candidate ticks ONE row; the autosave still goes as before.
    s.saveAnswer('7', '30', Response(lines: <String>['r1y']));
    await t.runAsync(s.flushAnswers);
    expect(posts, contains('answer'));

    _review(s);
    await _mount(t, s);

    expect(_said(t, 'Every question has an answer.'), isFalse);
    expect(_said(t, '1 question is partly answered.'), isTrue);

    await t.tap(find.text('Submit Assessment'));
    await t.pumpAndSettle();

    expect(find.text('Submit with 1 incomplete?'), findsOneWidget);
    expect(find.text('Q3 - 2 of 3 rows unanswered.'), findsOneWidget);

    // A real gate: backing out submits nothing.
    await t.tap(find.text('Go Back and Answer'));
    await t.pumpAndSettle();
    expect(posts, isNot(contains('submit')));
  });

  testWidgets('after a reload the server count still gates Submit', (
    WidgetTester t,
  ) async {
    // Nothing answered this session: only `rows_unanswered` knows.
    final List<String> posts = <String>[];
    final AppStore s = _store(posts);
    _review(s, rowsUnanswered: 2);
    await _mount(t, s);

    expect(_said(t, 'Every question has an answer.'), isFalse);
    await t.tap(find.text('Submit Assessment'));
    await t.pumpAndSettle();
    expect(find.text('Q3 - 2 rows unanswered.'), findsOneWidget);
    await t.tap(find.text('Go Back and Answer'));
    await t.pumpAndSettle();
    expect(posts, isNot(contains('submit')));
  });

  testWidgets('the server saying 0 blank rows is fully answered', (
    WidgetTester t,
  ) async {
    final AppStore s = _store(<String>[]);
    _review(s, rowsUnanswered: 0);
    await _mount(t, s);
    expect(_said(t, 'Every question has an answer.'), isTrue);
  });

  testWidgets('partly answered has its own legend, and the counts agree', (
    WidgetTester t,
  ) async {
    final AppStore s = _store(<String>[]);
    _review(s, rowsUnanswered: 2);
    await _mount(t, s);

    expect(find.text('Partly answered'), findsOneWidget);
    // One rule: a question holding an answer, whole or partial.
    expect(find.text('3 of 3 answered, 1 partly'), findsOneWidget);
    expect(find.bySemanticsLabel('3 of 3 questions answered'), findsOneWidget);
  });
}
