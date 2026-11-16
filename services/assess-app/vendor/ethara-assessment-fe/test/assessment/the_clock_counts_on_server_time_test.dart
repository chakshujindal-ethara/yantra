// The countdown runs on the SERVER's clock.
//
// The runner compared the server's `deadline` with the DEVICE clock. A device
// running slow showed time the server had already taken away, so its last
// answer - and the flush at its own time-up - landed past the 10s grace and
// was refused; a fast device ended the candidate's time early. Every payload
// that carries `deadline` now carries `server_now`, and the runner counts on
// device now + (server_now - device now at arrival).
@TestOn('vm')
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/screens/exam/exam_screen.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';

const String kToken = 'tok-skew';

/// A sitting whose server clock reads [serverNow] and whose deadline is
/// [deadline], both as the server sends them.
AppStore _store(DateTime serverNow, DateTime deadline) {
  final AppStore s = AppStore();
  s.portal = Portal.member;
  s.source = DataSource.live;
  s.meId = '2';
  s.attempts = <Attempt>[
    Attempt.fromJson(<String, dynamic>{
      'id': 7,
      'access_token': kToken,
      'assessment_id': 21,
      'state': 'in_progress',
      'started_at': deadline
          .subtract(const Duration(minutes: 45))
          .toUtc()
          .toIso8601String(),
      'deadline': deadline.toUtc().toIso8601String(),
      'server_now': serverNow.toUtc().toIso8601String(),
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
  return s;
}

Future<void> _open(WidgetTester t, AppStore s) async {
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
}

void main() {
  testWidgets('a device 60s slow shows the server time left and times up on '
      'the server deadline', (WidgetTester t) async {
    t.view.physicalSize = const Size(1400, 2400);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);

    // The device is 60s behind the server; the server gives 30s more.
    final DateTime serverNow = DateTime.now().add(const Duration(seconds: 60));
    await _open(
      t,
      _store(serverNow, serverNow.add(const Duration(seconds: 30))),
    );
    expect(
      find.byWidgetPredicate(
        (Widget w) =>
            w is Text && RegExp(r'^00:(29|30)$').hasMatch(w.data ?? ''),
      ),
      findsOneWidget,
      reason: '30s left on the server clock, not the 1:30 the device reads',
    );
    await t.pump(const Duration(seconds: 1));
    expect(find.text('Time is up'), findsNothing);

    // A fresh sitting: the server's deadline has just passed, while the
    // device still reads 59s left.
    await t.pumpWidget(const SizedBox());
    final DateTime serverNow2 = DateTime.now().add(const Duration(seconds: 60));
    await _open(
      t,
      _store(serverNow2, serverNow2.subtract(const Duration(seconds: 1))),
    );
    await t.pump(const Duration(seconds: 1));
    await t.pump();
    expect(
      find.text('Time is up'),
      findsOneWidget,
      reason: 'time-up fires on the server deadline, not 60s after it',
    );
    await t.pump(const Duration(seconds: 4));
  });

  test('a right device clock reads no offset; a real skew is kept (L7)', () {
    Duration offset(Duration skew) => Attempt.fromJson(<String, dynamic>{
      'id': 7,
      'access_token': kToken,
      'assessment_id': 21,
      'server_now': DateTime.now().add(skew).toUtc().toIso8601String(),
    }).clockOffset;

    // `server_now` is whole seconds and has no latency correction, so a
    // CORRECT device clock read up to ~2s behind it and time-up fired after
    // the server's deadline. That is noise, not skew.
    expect(offset(const Duration(milliseconds: 1500)), Duration.zero);
    expect(offset(const Duration(milliseconds: -900)), Duration.zero);
    expect(
      offset(const Duration(seconds: 3)).inMilliseconds,
      closeTo(3000, 250),
    );
    expect(
      offset(const Duration(seconds: -60)).inMilliseconds,
      closeTo(-60000, 250),
    );
  });
}
