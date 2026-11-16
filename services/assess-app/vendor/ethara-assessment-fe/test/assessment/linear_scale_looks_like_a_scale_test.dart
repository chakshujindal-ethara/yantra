// A LINEAR SCALE LOOKS LIKE A SCALE, not a row of boxes.
//
// THE DEFECT, reported from stage as "Linear scale should look like it and not
// boxes". A `linearScale` axis rendered as N equal-width bordered cells - the
// same geometry as a row of choice boxes, and the same geometry a `rating` used
// before it became stars. So a 1-7 scale read as "pick one of these seven
// buttons": nothing about the control said the points were ORDERED, which is the
// entire meaning of a scale, and Form Studio previewed a control the candidate
// never saw.
//
// AND THE ENDS OF THE RANGE WERE NOWHERE ON IT. An examiner names them in the
// designer (`scale_min_label`/`scale_max_label`); publish folds them into the
// question's description as "Scale: 1 = Unsure, 5 = Certain" because the boxed
// control had no room for them. The candidate therefore got seven numbers and a
// line of prose above them, and had to work out for themselves which end was
// which.
//
// WHAT IS ASSERTED HERE. The two halves that make it read as a range: one
// continuous track behind the points, filled up to the answer so the answer's
// POSITION is visible; and the examiner's end labels drawn ON the control, with
// the now-duplicated legend line gone from the prose above it.
//
// WHAT MUST NOT CHANGE, and is asserted just as hard: the stored answer. A scale
// still writes exactly ONE option - the one whose label is the chosen point - so
// the answer key, the mark arithmetic and every admin screen are untouched. Only
// the drawing differs. A `rating` keeps its stars, and an axis with no authored
// kind keeps the old radio stack.
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

/// The legend the publish path composes for an examiner's end labels, verbatim
/// from `studio_form._item_spec`.
const String kLegend = 'Scale: 1 = Linear Scale 1, 7 = Linear Scale 7';

Map<String, dynamic> _question({
  String kind = 'linearScale',
  int points = 7,
  String desc = kLegend,
}) => <String, dynamic>{
  'id': '10',
  'index': 1,
  'total': 1,
  'name': 'Linear Scale Ques',
  'prompt': 'How confident are you?',
  'description': desc,
  'question_type': 'mcq',
  'dimensions': <Map<String, dynamic>>[
    <String, dynamic>{
      'id': 100,
      'name': 'Answer',
      'input_kind': kind,
      'options': <Map<String, dynamic>>[
        for (int i = 1; i <= points; i++)
          <String, dynamic>{'id': 1000 + i, 'label': '$i'},
      ],
    },
  ],
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

Map<String, dynamic> _envelope({
  String kind = 'linearScale',
  int points = 7,
  String desc = kLegend,
}) => <String, dynamic>{
  'outcome': 'question',
  'assessment': <String, dynamic>{
    'id': 21,
    'name': 'Scale paper',
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
  'question': _question(kind: kind, points: points, desc: desc),
  'answered_question_ids': <dynamic>[],
  'progress_percent': 0,
};

/// Every POST body the screen sent, so the stored answer can be asserted.
final List<Map<String, dynamic>> _saves = <Map<String, dynamic>>[];

AppStore _store({
  String kind = 'linearScale',
  int points = 7,
  String desc = kLegend,
}) {
  final http.Client server = MockClient((http.Request req) async {
    Map<String, dynamic> data = <String, dynamic>{};
    if (req.url.path.endsWith('/state')) {
      data = _envelope(kind: kind, points: points, desc: desc);
    } else if (req.method == 'POST' && req.url.path.endsWith('/answer')) {
      _saves.add(jsonDecode(req.body) as Map<String, dynamic>);
    }
    return http.Response(
      jsonEncode(<String, dynamic>{'ok': true, 'data': data}),
      200,
      headers: <String, String>{'content-type': 'application/json'},
    );
  });
  final AppStore s = AppStore(
    api: ApiClient(baseUrl: 'http://stub', client: server, bearer: 'tok'),
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
      'name': 'Scale paper',
      'state': 'in_progress',
      'duration_minutes': 45,
    }),
  ];
  s.examByToken[kToken] = ExamView.fromJson(
    _envelope(kind: kind, points: points, desc: desc),
  );
  return s;
}

AppStore? _lastStore;

Future<void> _open(
  WidgetTester t, {
  String kind = 'linearScale',
  int points = 7,
  String desc = kLegend,
}) async {
  t.view.physicalSize = const Size(1400, 3000);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  _saves.clear();
  final AppStore store = _store(kind: kind, points: points, desc: desc);
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

/// The rendered width of a keyed widget, which is what says the track spans the
/// range rather than being one point's worth of decoration.
double _widthOf(WidgetTester t, Key k) => t.getSize(find.byKey(k)).width;

void main() {
  group('the control is a range, not a row of boxes', () {
    testWidgets('one continuous track runs behind every point', (
      WidgetTester t,
    ) async {
      await _open(t);

      expect(
        find.byKey(const Key('axis-scale')),
        findsOneWidget,
        reason: 'a scale is ONE question with seven points',
      );
      // THE POINT OF THE WHOLE CHANGE. A row of boxes has no track; a scale is
      // a line the points sit on.
      expect(
        find.byKey(const Key('scale-track')),
        findsOneWidget,
        reason:
            'without a track behind the points the control is a row of '
            'buttons, which is what was reported',
      );
      for (int i = 1; i <= 7; i++) {
        expect(
          find.text('$i'),
          findsOneWidget,
          reason: 'every point of the authored range must still be pickable',
        );
      }
      // A track that spans the range, not one cell of it.
      final double track = _widthOf(t, const Key('scale-track'));
      final double row = _widthOf(t, const Key('axis-scale'));
      expect(
        track,
        greaterThan(row / 2),
        reason:
            'the track has to cross the range - it is what makes the '
            'points read as ordered',
      );
    });

    testWidgets('nothing is filled until the candidate answers', (
      WidgetTester t,
    ) async {
      await _open(t);

      expect(
        find.byKey(const Key('scale-fill')),
        findsNothing,
        reason: 'an unanswered scale must not look part-way answered',
      );
    });

    testWidgets('answering fills the track up to the chosen point', (
      WidgetTester t,
    ) async {
      await _open(t);

      await t.tap(find.text('5'));
      await t.pumpAndSettle();
      // Let the debounced autosave fire so the tree tears down cleanly.
      await t.pump(const Duration(seconds: 2));

      // WHERE IN THE RANGE the answer sits is the thing a scale communicates
      // and a row of boxes cannot: 5 of 7 is most of the way along.
      expect(find.byKey(const Key('scale-fill')), findsOneWidget);
      final double fill = _widthOf(t, const Key('scale-fill'));
      final double track = _widthOf(t, const Key('scale-track'));
      expect(
        fill / track,
        closeTo(4 / 6, .02),
        reason: 'point 5 of 7 is four of the six gaps along the track',
      );
    });

    testWidgets('picking a LOWER point shortens the fill', (
      WidgetTester t,
    ) async {
      // Guards the fill against being cosmetic: it has to track the answer
      // both ways, not just grow.
      await _open(t);

      await t.tap(find.text('6'));
      await t.pumpAndSettle();
      final double high = _widthOf(t, const Key('scale-fill'));
      await t.tap(find.text('2'));
      await t.pumpAndSettle();
      await t.pump(const Duration(seconds: 2));

      expect(_widthOf(t, const Key('scale-fill')), lessThan(high));
    });

    testWidgets('the first point selected leaves no fill, but is selected', (
      WidgetTester t,
    ) async {
      // The bottom of the range is zero gaps along, so there is no line to
      // draw - and an answer that renders identically to "unanswered" would be
      // a worse bug than the one being fixed. The MARK carries it.
      await _open(t);

      await t.tap(find.text('1'));
      await t.pumpAndSettle();
      await t.pump(const Duration(seconds: 2));

      expect(find.byKey(const Key('scale-fill')), findsNothing);
      final AppStore s = _lastStore!;
      expect(
        s.responseFor(s.attempts.first, s.examByToken[kToken]!.question!).lines,
        <String>['1001'],
        reason: 'the lowest point is a real answer and must be stored as one',
      );
    });
  });

  group('the ends of the range are named on the control', () {
    testWidgets("the examiner's end labels are drawn on the scale", (
      WidgetTester t,
    ) async {
      await _open(t);

      // Authored as scale_min_label/scale_max_label, and previously reachable
      // only by reading the legend sentence above the control.
      expect(find.text('Linear Scale 1'), findsOneWidget);
      expect(find.text('Linear Scale 7'), findsOneWidget);
    });

    testWidgets('the legend line is not printed twice', (WidgetTester t) async {
      await _open(t);

      expect(
        find.textContaining('Scale: 1 ='),
        findsNothing,
        reason:
            'the control draws the ends now, so the prose line above it '
            'would repeat both labels directly above themselves',
      );
    });

    testWidgets('help text the examiner wrote SURVIVES the legend strip', (
      WidgetTester t,
    ) async {
      // Only the legend sentence goes. The description is also where the
      // examiner's own help text lives, and publish appends the legend to it.
      await _open(t, desc: 'Linear Scale help text\n\n$kLegend');

      expect(find.text('Linear Scale help text'), findsOneWidget);
      expect(find.textContaining('Scale: 1 ='), findsNothing);
    });

    testWidgets('a scale with NO authored end labels keeps its description', (
      WidgetTester t,
    ) async {
      // Publish writes the BOUND itself when a label is blank ("1 = 1"), which
      // says nothing the number above the mark does not - so no labels are
      // drawn, and nothing may be stripped either.
      await _open(t, desc: 'Scale: 1 = 1, 7 = 7');

      expect(
        find.textContaining('Scale: 1 ='),
        findsOneWidget,
        reason: 'nothing replaced this line, so removing it would lose it',
      );
    });

    testWidgets('a description with no legend at all is untouched', (
      WidgetTester t,
    ) async {
      await _open(t, desc: 'Read the brief before answering.');

      expect(find.text('Read the brief before answering.'), findsOneWidget);
    });
  });

  group('the stored answer is unchanged', () {
    testWidgets('tapping a point stores exactly ONE option', (
      WidgetTester t,
    ) async {
      await _open(t);

      await t.tap(find.text('5'));
      await t.pumpAndSettle();
      await t.pump(const Duration(seconds: 2));

      // THE SCORING CONTRACT. A scale is stored as `mcq` - one keyed option -
      // so a redraw that stored a number, or two options, would break the
      // answer key and every mark on the paper.
      final AppStore s = _lastStore!;
      final Response saved = s.responseFor(
        s.attempts.first,
        s.examByToken[kToken]!.question!,
      );
      expect(saved.lines, <String>['1005']);
      expect(_saves, isNotEmpty, reason: 'the answer must reach the server');
      expect(
        (_saves.last['selected_option_ids'] as List<dynamic>).length,
        1,
        reason: 'one point picked is one option on the wire',
      );
    });

    testWidgets('a second tap REPLACES the first, it does not add to it', (
      WidgetTester t,
    ) async {
      await _open(t);

      await t.tap(find.text('2'));
      await t.pumpAndSettle();
      await t.tap(find.text('6'));
      await t.pumpAndSettle();
      await t.pump(const Duration(seconds: 2));

      final AppStore s = _lastStore!;
      expect(
        s.responseFor(s.attempts.first, s.examByToken[kToken]!.question!).lines,
        <String>['1006'],
        reason: 'a scale is pick-one; two stored points would score as an msq',
      );
    });
  });

  group('the other controls are untouched', () {
    testWidgets('a rating keeps its stars and grows no track', (
      WidgetTester t,
    ) async {
      // `rating` and `linearScale` sharing one widget is the defect this file's
      // sibling fixed; the scale redraw must not undo it.
      await _open(t, kind: 'rating', points: 5, desc: '');

      expect(find.byKey(const Key('axis-rating')), findsOneWidget);
      expect(find.byKey(const Key('axis-scale')), findsNothing);
      expect(find.byKey(const Key('scale-track')), findsNothing);
    });

    testWidgets('an axis with no authored kind keeps the radio stack', (
      WidgetTester t,
    ) async {
      await _open(t, kind: '', points: 3, desc: '');

      expect(find.byKey(const Key('scale-track')), findsNothing);
      expect(find.byKey(const Key('axis-scale')), findsNothing);
    });
  });
}
