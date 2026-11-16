// A labelling question tells the candidate to read markers that are there.
//
// THE BUG. "Click the image to zoom and pan. The numbered overlay marks each
// region you need to name." was printed unconditionally under the plate -
// outside the `marked == null` branch and outside any check on the boxes.
// Markers reach the screen two ways: the baked plate, used only when boxes AND
// an `annotated_url` both exist (the server sends '' unless
// `annotated_is_worker_safe` passes), and the client-drawn overlay, which needs
// the `{number, box_2d}` pairs `_label_boxes` sends only when every marker has
// geometry. A defect question whose markers lack geometry gets neither, so the
// candidate saw an unmarked photograph, inputs labelled BOX 1..N, and a
// sentence telling them to read markers that are not on screen.
@TestOn('vm')
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/screens/exam/answer_layouts.dart';
import 'package:ethara_assessment/assessment/screens/exam/stimulus.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';

const String kQid = '55';
const String kOverlaySentence = 'The numbered overlay marks each region';

/// One labelling question, as `question_for_candidate` sends it.
///
/// [geometry] true: `{number, box_2d}` pairs, what `_label_boxes` returns when
/// every marker has geometry, plus an overlay URL. False: bare integers and an
/// empty `annotated_url`, so nothing is drawn at all.
Question _labelQuestion({required bool geometry, bool? baked}) =>
    Question.fromJson(<String, dynamic>{
      'id': kQid,
      'index': 1,
      'total': 1,
      'name': 'Name each marked part',
      'prompt': 'Name each marked part of the truck.',
      'question_type': 'image_label',
      'images': <Map<String, dynamic>>[
        <String, dynamic>{
          'slot': 'single',
          'url': 'https://img.test/plate.png',
          'annotated_url': (baked ?? geometry)
              ? 'https://img.test/plate-marked.png'
              : '',
        },
      ],
      'videos': <dynamic>[],
      'label_boxes': geometry
          ? <Map<String, dynamic>>[
              <String, dynamic>{
                'number': 1,
                'box_2d': <int>[100, 100, 300, 300],
              },
              <String, dynamic>{
                'number': 2,
                'box_2d': <int>[400, 400, 600, 600],
              },
            ]
          : <int>[1, 2],
      'answer': <String, dynamic>{
        'answered': false,
        'selected_option_ids': <dynamic>[],
        'justification': '',
        'label_answers': <String, dynamic>{},
      },
    });

Future<void> _pump(WidgetTester t, Question q) async {
  t.view.physicalSize = const Size(1200, 2400);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);

  final AppStore store = AppStore();
  final Attempt ev = Attempt(
    id: 'att-1',
    assessmentId: 'a-1',
    employeeId: 'e-1',
    token: 'tok',
    resp: <String, Response>{kQid: Response.seed(q)},
  );
  store.attempts = <Attempt>[ev];

  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: SingleChildScrollView(
          child: AnswerArea(store: store, ev: ev, q: q, readOnly: true),
        ),
      ),
    ),
  );
  await t.pump();
}

void main() {
  testWidgets('bare numbers: the caption does not promise an overlay', (
    WidgetTester t,
  ) async {
    final Question q = _labelQuestion(geometry: false);
    // The precondition, so this cannot pass against a payload that quietly
    // still carries geometry.
    expect(q.labelBoxes, <int>[1, 2]);
    expect(q.images.single.regions, isEmpty);

    await _pump(t, q);

    final List<String> text = t
        .widgetList<Text>(find.byType(Text))
        .map((Text w) => w.data ?? w.textSpan?.toPlainText() ?? '')
        .toList();
    expect(
      text.where((String s) => s.contains(kOverlaySentence)),
      isEmpty,
      reason: 'there are no markers on this picture to read',
    );
    // The boxes are still numbered, so the caption has to say what the numbers
    // refer to rather than going silent.
    expect(find.textContaining('numbered markers'), findsOneWidget);
  });

  testWidgets('with markers drawn, the caption is the one that explains them', (
    WidgetTester t,
  ) async {
    final Question q = _labelQuestion(geometry: true);
    expect(q.images.single.regions, hasLength(2));

    await _pump(t, q);

    expect(find.textContaining(kOverlaySentence), findsOneWidget);
  });

  // ONE OVERLAY (q1170 showed 4 drawn panels over 17 baked markers): drawn
  // regions go on the PLAIN picture, the baked one only when nothing is drawn.
  testWidgets('drawn regions never sit on the baked picture', (
    WidgetTester t,
  ) async {
    await _pump(t, _labelQuestion(geometry: true));

    final StimulusPlate plate = t.widget(find.byType(StimulusPlate));
    expect(plate.asset.url, 'https://img.test/plate.png');
    expect(plate.asset.regions, hasLength(2));
  });

  testWidgets('bare numbers use the baked picture', (WidgetTester t) async {
    await _pump(t, _labelQuestion(geometry: false, baked: true));

    final StimulusPlate plate = t.widget(find.byType(StimulusPlate));
    expect(plate.asset.url, 'https://img.test/plate-marked.png');
  });
}
