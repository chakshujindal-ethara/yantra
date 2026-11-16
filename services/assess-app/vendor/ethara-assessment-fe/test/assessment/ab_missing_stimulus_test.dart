// AN A/B QUESTION WITH NO PLATES MUST SAY SO.
//
// WHAT WENT WRONG. `_ImageAbLayout` built its stimulus as
// `for (final Asset a in q.images) StimulusPlate(...)`. With `images` empty
// that loop produces an EMPTY Column - no plate, no caption, no warning - so an
// `image_ab` question rendered as nothing but its axes and looked exactly like
// an ordinary six-axis question.
//
// HOW IT SURFACED. A generated `image_ab` draft whose plates HAD rendered (two
// real PNGs on the record, `image_state = rendered`) showed no picture in the
// Drafts-tab preview, because the drafts LIST route deliberately omits image
// payloads and the sheet was reading a thin row. The bug was not the missing
// data - it was that missing data was indistinguishable from a question that
// never had any. A reviewer could approve a picture-less A/B question and
// nothing on screen would have hinted at it.
//
// Every other layout in answer_layouts.dart already used `MissingStimulus` for
// exactly this; the A/B branch was the one that did not. `allMedia` is the
// shared helper that returns it, so this branch now behaves like the rest.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/screens/exam/answer_layouts.dart';
import 'package:ethara_assessment/assessment/screens/exam/stimulus.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';

const String _qid = 'q-ab';

/// The six-axis audit template shape, which is what made this invisible: with
/// this many axes the sheet looks busy and complete whether or not there is a
/// picture at the top of it.
Question _ab({List<Asset> images = const <Asset>[]}) => Question(
  id: _qid,
  genId: 'gen-1',
  type: QType.imageAb,
  name: 'Audit Image Reference Sets (Pass/Fail)',
  prompt: 'Audit the main image and its reference images for quality and match.',
  images: images,
  dims: const <QDimension>[
    QDimension(
      code: 'D1',
      name: 'Is the Picture Sharp and Clear?',
      options: <QOption>[
        QOption(id: 'p', label: 'Pass'),
        QOption(id: 'f', label: 'Fail'),
      ],
    ),
    QDimension(
      code: 'D2',
      name: 'Does This Look Like a Real Image (Not AI)?',
      options: <QOption>[
        QOption(id: 'p2', label: 'Pass'),
        QOption(id: 'f2', label: 'Fail'),
      ],
    ),
  ],
);

Future<void> _pump(WidgetTester tester, Question q) async {
  tester.view.physicalSize = const Size(1000, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final AppStore store = AppStore();
  final Attempt ev = Attempt(
    id: 'att-1',
    assessmentId: 'a-1',
    employeeId: 'e-1',
    token: 'tok',
    resp: <String, Response>{_qid: Response.seed(q)},
  );
  store.attempts = <Attempt>[ev];

  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: ListenableBuilder(
          listenable: store,
          builder: (BuildContext _, Widget? child) => SingleChildScrollView(
            child: AnswerArea(store: store, ev: ev, q: q, readOnly: true),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('with no plates it shows the missing-stimulus state', (
    WidgetTester tester,
  ) async {
    await _pump(tester, _ab());
    expect(
      find.byType(MissingStimulus),
      findsOneWidget,
      reason: 'an A/B question with no picture must not look like a normal '
          'question - a reviewer has to see that the plates are absent '
          'BEFORE approving it into the bank',
    );
    expect(find.byType(StimulusPlate), findsNothing);
  });

  testWidgets('the axes still render, so the warning is additive', (
    WidgetTester tester,
  ) async {
    await _pump(tester, _ab());
    expect(find.text('IS THE PICTURE SHARP AND CLEAR?'), findsOneWidget);
    expect(
      find.text('DOES THIS LOOK LIKE A REAL IMAGE (NOT AI)?'),
      findsOneWidget,
    );
  });

  testWidgets('with both plates it draws them, captioned', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      _ab(
        images: const <Asset>[
          Asset(id: '756-a', url: '/x/a.png', label: 'Response A'),
          Asset(id: '756-b', url: '/x/b.png', label: 'Response B'),
        ],
      ),
    );
    expect(find.byType(MissingStimulus), findsNothing);
    expect(
      find.byType(StimulusPlate),
      findsNWidgets(2),
      reason: 'an A/B pair is both plates or it is not a comparison',
    );
    // The caption is the only thing saying which side is which. Pass/Fail
    // axes name no side, so the pair is a left and a right image, not
    // Response A and Response B (a_yes_no_comparison_names_no_response_test).
    expect(find.text('LEFT IMAGE'), findsOneWidget);
    expect(find.text('RIGHT IMAGE'), findsOneWidget);
    expect(find.text('RESPONSE A'), findsNothing);
  });
}
