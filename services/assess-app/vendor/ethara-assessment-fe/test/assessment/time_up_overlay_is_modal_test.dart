// MT3-02: the time-up overlay is modal for the keyboard too.
//
// It blocked the pointer but not focus: the answer box kept the focus it had,
// Tab walked from "See my submission" into Next and the textarea behind it,
// and whatever was typed there was autosaved after the deadline. The answer
// typed BEFORE the buzzer, still inside the debounce, is sent at once instead.
@TestOn('vm')
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/exam/exam_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';

const String kToken = 'tok-mt302';

void main() {
  testWidgets('time-up flushes the pending answer once and takes the paper '
      'out of keyboard reach', (WidgetTester t) async {
    final SemanticsHandle sem = t.ensureSemantics();
    final List<String> answers = <String>[];
    final DateTime gone = DateTime.now().subtract(const Duration(minutes: 1));
    final AppStore s = AppStore(
      api: ApiClient(
        baseUrl: 'http://stub',
        client: MockClient((http.Request req) async {
          if (req.url.path.endsWith('/answer')) answers.add(req.body);
          return http.Response(
            jsonEncode(<String, dynamic>{
              'ok': true,
              'data': <String, dynamic>{},
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
        bearer: 't',
      ),
      // Far longer than the test runs, so only the flush can send it.
      answerDebounce: const Duration(seconds: 30),
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
        'started_at': gone
            .subtract(const Duration(minutes: 45))
            .toUtc()
            .toIso8601String(),
        'deadline': gone.toUtc().toIso8601String(),
      }),
    ];
    s.assessments = <Assessment>[
      Assessment.fromJson(<String, dynamic>{
        'id': 21,
        'name': 'sample test',
        'state': 'in_progress',
        'duration_minutes': 45,
      }),
    ];
    s.examByToken[kToken] = ExamView.fromJson(<String, dynamic>{
      'outcome': 'question',
      'question': <String, dynamic>{
        'id': '10',
        'index': 1,
        'total': 3,
        'name': 'Question 1',
        'prompt': 'Prompt.',
        'question_type': 'subjective_rubric',
        'dimensions': <dynamic>[],
        'images': <dynamic>[],
        'videos': <dynamic>[],
        'label_boxes': <dynamic>[],
      },
      'answered_question_ids': <dynamic>[],
      'progress_percent': 0,
    });

    t.view.physicalSize = const Size(1400, 2400);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: AssessmentNavScope(
          nav: AssessmentNav(),
          child: ExamScreen(store: s, token: kToken, sub: ExamSub.question),
        ),
      ),
    );
    await t.pump();

    await t.enterText(find.byType(TextField).first, 'Typed before the buzzer');
    final FocusNode field = t
        .widget<EditableText>(find.byType(EditableText).first)
        .focusNode;
    expect(field.hasFocus, isTrue);
    expect(answers, isEmpty, reason: 'still inside the 30s debounce');

    // The clock's first tick finds the deadline passed.
    await t.pump(const Duration(seconds: 1));
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await t.pump();
    expect(find.text('Time is up'), findsOneWidget);
    expect(answers, hasLength(1), reason: 'flushed at once, not in 30s');
    expect(answers.single, contains('Typed before the buzzer'));

    // The answer box let go of the keyboard, and Tab stays on the overlay.
    expect(field.hasFocus, isFalse);

    // AND THE HEADING HAS IT (L6). Let go of by the answer box and requested
    // by nobody, the focus fell to the page: a browser left it on the page
    // container, not on "Time is up" as before this round.
    await t.pump();
    expect(
      t.getSemantics(find.text('Time is up')),
      isSemantics(isHeader: true, isFocused: true),
    );

    for (int i = 0; i < 4; i++) {
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pump();
      expect(field.hasFocus, isFalse, reason: 'Tab $i reached the answer box');
      expect(
        FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<BlockOverlay>(),
        isNotNull,
        reason: 'Tab $i left the overlay for the paper behind it',
      );
    }

    // The cancelled debounce never fires a second copy.
    await t.pump(const Duration(seconds: 40));
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    expect(answers, hasLength(1));
    sem.dispose();
  });
}
