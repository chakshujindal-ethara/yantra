// A generated labelling question can be OPENED in the annotation editor.
//
// THE DEFECT (SNo 168). The annotation editor is built and works - verified
// live on a real plate: numbered boxes drawn over the image, a Point 1..N chip
// row, and a "Golden answers (for the LLM judge)" panel counting how many are
// keyed. What was missing was the path INTO it from a generated question:
// `studio_form._item_spec` translated designer -> question and nothing came
// back, so an examiner who could see box 4 in the wrong place had no way to
// move it.
//
// WHAT THESE TESTS PIN, and why each one is shaped the way it is:
//
//  * THE BOXES ARRIVE PRE-FILLED. `an item from the server opens with its boxes
//    and keys` mounts the REAL editor against the REAL wire payload. A test
//    that only checked the store's parsing would pass while the editor rendered
//    an empty plate, which is the symptom that was actually reported.
//
//  * THE EDIT GOES BACK ONTO THE SAME QUESTION. `saving posts the edited item
//    back to the same question` reads the recorded request path and body. This
//    is the product decision - edit in place, no new Studio record - and it is
//    only observable at the wire.
//
//  * AN UNKEYED POINT CANNOT BE SAVED. The server refuses it
//    (`_item_spec` does the same on publish) because an unkeyed point is a mark
//    no candidate can earn. Refusing in the editor too means the examiner reads
//    the reason beside the field rather than as a toast after a round trip.
//
//  * `not_annotatable` IS AN ANSWER, NOT AN ERROR. It is how the client decides
//    whether to offer the action at all. Surfacing it as a failed call would
//    put a red toast on every non-labelling question an admin opens.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/form_models.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/widgets/annotation_editor_sheet.dart';
import 'package:ethara_assessment/assessment/widgets/buttons.dart';
import 'package:ethara_assessment/assessment/widgets/controls.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';

/// The item `GET /api/v1/bank/<id>/studio_item` answers with, in the shape
/// `Question.as_studio_annotation_item` actually emits: fractional x/y/w/h and
/// string-keyed golden labels.
const Map<String, dynamic> kItem = <String, dynamic>{
  'kind': 'imageAnnotation',
  'title': 'Mark each defect',
  'help': 'Name what is wrong at each marker.',
  'media_url': 'https://example.test/plate.png',
  'regions': <dynamic>[
    <String, dynamic>{'n': 1, 'x': 0.08, 'y': 0.10, 'w': 0.22, 'h': 0.20},
    <String, dynamic>{'n': 2, 'x': 0.42, 'y': 0.38, 'w': 0.20, 'h': 0.18},
  ],
  'annotation_count': 2,
  'golden_labels': <String, dynamic>{
    '1': 'Style drift',
    '2': 'Edge artefact',
  },
  'required': true,
};

/// Every request the store made, so a test can assert what went where.
final List<({String path, Map<String, dynamic> body})> sent =
    <({String path, Map<String, dynamic> body})>[];

http.Client server({
  Object? item = kItem,
  String? failCode,
  int status = 200,
}) => MockClient((http.Request req) async {
  final Map<String, dynamic> body =
      req.body.isEmpty
      ? <String, dynamic>{}
      : (jsonDecode(req.body) as Map<String, dynamic>);
  sent.add((path: req.url.path, body: body));

  if (req.url.path.endsWith('/studio_item') && failCode != null) {
    return http.Response(
      jsonEncode(<String, dynamic>{
        'ok': false,
        'error': <String, dynamic>{
          'code': failCode,
          'message': 'This question has no image markers to edit.',
        },
      }),
      status,
      headers: <String, String>{'content-type': 'application/json'},
    );
  }
  if (req.url.path.endsWith('/studio_item/save') && failCode != null) {
    return http.Response(
      jsonEncode(<String, dynamic>{
        'ok': false,
        'error': <String, dynamic>{
          'code': failCode,
          'message': 'Every point needs a golden answer. Missing: 2.',
        },
      }),
      status,
      headers: <String, String>{'content-type': 'application/json'},
    );
  }
  if (req.url.path.endsWith('/studio_item')) {
    return http.Response(
      jsonEncode(<String, dynamic>{
        'ok': true,
        'data': <String, dynamic>{'question_id': 9602, 'item': item},
      }),
      200,
      headers: <String, String>{'content-type': 'application/json'},
    );
  }
  // Everything else - the save's 200, and the `refresh` + `loadQuestion` that
  // follow it - answers empty rather than 404, so a hydration failure does not
  // masquerade as the behaviour under test.
  return http.Response(
    jsonEncode(<String, dynamic>{'ok': true, 'data': <String, dynamic>{}}),
    200,
    headers: <String, String>{'content-type': 'application/json'},
  );
});

AppStore store(http.Client c) =>
    AppStore(api: ApiClient(baseUrl: 'http://stub', client: c, bearer: 'stub'))
      ..portal = Portal.admin
      ..source = DataSource.live;

Widget mount(Widget child) =>
    MaterialApp(theme: ThemeData.dark(), home: Scaffold(body: child));

void main() {
  setUp(sent.clear);

  group('opening the editor', () {
    test('the wire item parses into an annotation item with its boxes', () {
      final FormItem it = FormItem.fromJson(kItem);

      expect(it.kind, FormItemKind.imageAnnotation);
      expect(it.regions.map((LabelRegion r) => r.number), <int>[1, 2]);
      expect(it.regions.first.x, closeTo(0.08, 0.001));
      expect(it.regions.first.y, closeTo(0.10, 0.001));
      expect(it.goldenLabels[1], 'Style drift');
      expect(it.goldenLabels[2], 'Edge artefact');
      expect(it.mediaUrl, 'https://example.test/plate.png');
    });

    test('a question with no markers answers null, and does NOT toast',
        () async {
      // `not_annotatable` is how the client decides whether to offer the
      // action. A red toast here would fire on every non-labelling question an
      // admin opens.
      final AppStore s = store(
        server(failCode: 'not_annotatable', status: 404),
      );

      final Map<String, dynamic>? item = await fetchAnnotationItem(s, '9602');

      expect(item, isNull);
      expect(s.toaster.items, isEmpty,
          reason: 'a not-annotatable question is an answer, not a failure');
    });

    test('any OTHER failure is surfaced', () async {
      // The negative half of the case above: swallowing every error would hide
      // a genuinely broken route behind a silently missing button.
      final AppStore s = store(server(failCode: 'server_error', status: 500));

      expect(await fetchAnnotationItem(s, '9602'), isNull);
      expect(s.toaster.items, isNotEmpty);
    });
  });

  group('the editor sheet', () {
    testWidgets('an item from the server opens with its boxes and keys',
        (WidgetTester t) async {
      t.view.physicalSize = const Size(1400, 2400);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);

      final AppStore s = store(server());
      final Map<String, dynamic>? item = await fetchAnnotationItem(s, '9602');
      expect(item, isNotNull);

      await t.pumpWidget(mount(
        Builder(
          builder: (BuildContext ctx) => TextButton(
            onPressed: () => showAnnotationEditor(ctx, s, '9602', item!),
            child: const Text('open'),
          ),
        ),
      ));
      await t.tap(find.text('open'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));

      // The MARKERS are on screen, which is the whole complaint: the editor
      // opened on a plate with nothing on it before this existed.
      expect(find.text('Point 1'), findsWidgets);
      expect(find.text('Point 2'), findsWidgets);
      // And the retroactive warning, in the same words the bank editor uses -
      // this rewrites an answer key everyone who has sat it is scored against.
      expect(
        find.text('Changes apply to everyone who has already sat it.'),
        findsOneWidget,
      );
    });

    testWidgets('saving posts the edited item back to the SAME question',
        (WidgetTester t) async {
      t.view.physicalSize = const Size(1400, 2400);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);

      final AppStore s = store(server());
      final Map<String, dynamic>? item = await fetchAnnotationItem(s, '9602');

      await t.pumpWidget(mount(
        Builder(
          builder: (BuildContext ctx) => TextButton(
            onPressed: () => showAnnotationEditor(ctx, s, '9602', item!),
            child: const Text('open'),
          ),
        ),
      ));
      await t.tap(find.text('open'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));

      await t.tap(find.widgetWithText(Btn, 'Save annotations'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));

      final Iterable<({Map<String, dynamic> body, String path})> saves =
          sent.where((({Map<String, dynamic> body, String path}) r) =>
              r.path.endsWith('/studio_item/save'));
      expect(saves, hasLength(1), reason: 'exactly one save, in place');
      // IN PLACE: the id opened is the id written. The whole product decision
      // is observable only here.
      expect(saves.first.path, contains('/bank/9602/studio_item/save'));

      final Map<String, dynamic> posted =
          saves.first.body['item'] as Map<String, dynamic>;
      expect(posted['kind'], 'imageAnnotation');
      // The geometry survives the round trip through the editor untouched. A
      // no-op save that moved every box is the corruption nobody looks for,
      // because the examiner changed nothing.
      final List<dynamic> regions = posted['regions'] as List<dynamic>;
      expect(regions, hasLength(2));
      expect((regions.first as Map<String, dynamic>)['n'], 1);
      expect((regions.first as Map<String, dynamic>)['x'],
          closeTo(0.08, 0.001));
      expect((regions.first as Map<String, dynamic>)['y'],
          closeTo(0.10, 0.001));
      expect(posted['golden_labels'],
          <String, String>{'1': 'Style drift', '2': 'Edge artefact'});

      // The success toast schedules its own 3.2s dismissal. Left pending it
      // trips the binding's timer check, which reads as a failure of the save.
      await t.pump(const Duration(seconds: 4));
    });

    testWidgets('no button is offered that the sheet cannot honour',
        (WidgetTester t) async {
      // FOUND BY ADVERSARIAL REVIEW, and it was real. The sheet first passed
      // `onDuplicate: () {}` / `onDelete: () {}` to satisfy two `required`
      // params, which left both icons rendered on the card: pressing Delete ran
      // its whole confirmation sheet - "This cannot be undone", a red Delete
      // Question button - and then toasted "Question deleted" over a question
      // that was still there.
      //
      // A question is ONE item on this sheet: there is nowhere to put a copy,
      // and deleting the QUESTION is the bank's own delete. So neither control
      // is offered, the same way `showDragHandle: false` stands down a drag
      // gesture that has no reorderable ancestor.
      t.view.physicalSize = const Size(1400, 2400);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);

      final AppStore s = store(server());
      final Map<String, dynamic>? item = await fetchAnnotationItem(s, '9602');

      await t.pumpWidget(mount(
        Builder(
          builder: (BuildContext ctx) => TextButton(
            onPressed: () => showAnnotationEditor(ctx, s, '9602', item!),
            child: const Text('open'),
          ),
        ),
      ));
      await t.tap(find.text('open'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));

      expect(find.byTooltip('Delete question'), findsNothing,
          reason: 'the sheet cannot delete a question, so it must not offer to');
      expect(find.byTooltip('Duplicate question'), findsNothing,
          reason: 'there is nowhere on this sheet for a copy to go');
      // The controls that DO work are still there - standing down the two inert
      // ones must not have stood down the editor itself.
      expect(find.text('Point 1'), findsWidgets);
      expect(find.widgetWithText(Btn, 'Save annotations'), findsOneWidget);
    });

    testWidgets('an unkeyed point cannot be saved', (WidgetTester t) async {
      t.view.physicalSize = const Size(1400, 2400);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);

      final AppStore s = store(server());
      // Marker 2 has no golden answer - a mark no candidate can earn, because
      // the judge has nothing to compare their description against. The server
      // refuses this on publish; refusing here means the examiner reads why
      // before spending a round trip on it.
      final Map<String, dynamic> half = <String, dynamic>{
        ...kItem,
        'golden_labels': <String, dynamic>{'1': 'Style drift'},
      };

      await t.pumpWidget(mount(
        Builder(
          builder: (BuildContext ctx) => TextButton(
            onPressed: () => showAnnotationEditor(ctx, s, '9602', half),
            child: const Text('open'),
          ),
        ),
      ));
      await t.tap(find.text('open'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));

      expect(
        find.textContaining('Every point needs a golden answer'),
        findsOneWidget,
        reason: 'the refusal names what is missing, beside the field',
      );
      final Finder save = find.widgetWithText(Btn, 'Save annotations');
      expect(save, findsOneWidget);
      final Btn btn = t.widget<Btn>(save.first);
      expect(btn.onPressed, isNull,
          reason: 'the save must be unpressable, not merely warned about');

      expect(
        sent.where((({Map<String, dynamic> body, String path}) r) =>
            r.path.endsWith('/studio_item/save')),
        isEmpty,
      );
    });
  });

  group('the editor cannot retype or mis-address a question', () {
    testWidgets('the kind picker offers only image annotation',
        (WidgetTester t) async {
      // FOUND BY ADVERSARIAL REVIEW. `FormItemEditor.allowedKinds` was declared
      // and NEVER READ, so the sheet's picker offered all fifteen kinds - and
      // this sheet saves back onto a BANK question. Retyping a labelling
      // question into an MCQ from here would rewrite what the paper ASKS, not
      // where a box sits, and the save route only understands annotations.
      t.view.physicalSize = const Size(1400, 2400);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);

      final AppStore s = store(server());
      final Map<String, dynamic>? item = await fetchAnnotationItem(s, '9602');

      await t.pumpWidget(mount(
        Builder(
          builder: (BuildContext ctx) => TextButton(
            onPressed: () => showAnnotationEditor(ctx, s, '9602', item!),
            child: const Text('open'),
          ),
        ),
      ));
      await t.tap(find.text('open'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));

      // Kind plus "is audio": Video and Audio share the `videoBlock` kind.
      final Iterable<SelectField<(FormItemKind, bool)>> pickers =
          t.widgetList<SelectField<(FormItemKind, bool)>>(
              find.byType(SelectField<(FormItemKind, bool)>));
      expect(pickers, hasLength(1), reason: 'one item, one kind picker');
      expect(
        pickers.first.options
            .map((((FormItemKind, bool), String) o) => o.$1.$1)
            .toList(),
        <FormItemKind>[FormItemKind.imageAnnotation],
        reason: 'a sheet that edits ONE labelling question must not offer to '
            'turn it into an MCQ',
      );
    });
  });
}
