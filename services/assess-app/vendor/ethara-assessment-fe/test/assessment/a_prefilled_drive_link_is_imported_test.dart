// A DRIVE LINK THE EXAMINER DID NOT TYPE MUST STILL BE IMPORTED.
//
// REPORTED: "when i import a json file which contains media links associated
// with its question, it comes prefilled but the media got stuck at copying -
// but when i copy paste and hit enter the same link it works."
//
// THE CAUSE. `_resolveShareLink` was wired to the media field's `onChanged`
// and to NOTHING else. A link that arrived any other way - a JSON import, a
// duplicated form, a task template, reopening a form saved before the import
// landed - was never resolved at all. The plate then drew the Drive share
// PAGE, which cannot render as a picture, and the failure text said "Copying
// that Drive file into this app..." because it was INFERRED from "this is a
// Drive url and nothing has failed yet" - equally true of an import that never
// started. So the examiner was told work was in progress while nothing at all
// was happening, indefinitely. Re-pasting the identical link appeared to fix
// it because pasting is the one path that was wired.
//
// A second, independent defect in the same routine: it parked on
// `await settled.future`, where `settled` was a Completer completed by a Timer.
// CANCELLING A TIMER DOES NOT COMPLETE ITS COMPLETER, so every cancellation -
// the next keystroke, or `dispose()` - stranded an await that could never
// resume, and its import never ran. The work now lives inside the timer
// callback, where a cancel simply means it never starts.
@TestOn('vm')
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/form_models.dart';
import 'package:ethara_assessment/assessment/screens/admin/form_item_editor.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';

const String _drivePage =
    'https://drive.google.com/file/d/1BXGsdltASyRaK4LxnnU0wc_rRSxaWEAw/view?usp=drive_link';
const String _driveVideo =
    'https://drive.google.com/file/d/1GrycVJ312pw_dQO4fVNElzE7CLtFFAqw/view';
const String _directImage = 'https://cdn.example.com/photo.png';

// ONE DRIVE FILE ID PER TEST THAT REFUSES. `_autoImportRefused` is deliberately
// session-scoped - a form re-opened after a refusal must not re-run the
// download - and a test file is one session, so two refusing tests sharing a
// url would silently exempt the second one.
const String _driveRestricted =
    'https://drive.google.com/file/d/1RESTRICTEDfileaaaaaaaaaaaaaaaa/view';
const String _driveReopened =
    'https://drive.google.com/file/d/1REOPENEDfilebbbbbbbbbbbbbbbbbb/view';

/// Records every path the client posts to, and answers the import route the
/// way the real server does.
class _Spy {
  final List<String> paths = <String>[];
  String contentType = 'image/jpeg';

  /// Answer the import route the way the server does for a file left shared
  /// "Restricted", which is the commonest Drive failure by a distance.
  bool refuse = false;

  /// How long the server holds the request. `/forms/media/import` is a
  /// blocking download on the server's side, so the interesting question is
  /// how many of them are in flight at once.
  Duration latency = Duration.zero;

  int _inFlight = 0;
  int peakConcurrent = 0;

  int get importCount =>
      paths.where((String p) => p.endsWith('/forms/media/import')).length;

  late final http.Client client = MockClient((http.Request req) async {
    paths.add(req.url.path);
    if (req.url.path.endsWith('/forms/media/import')) {
      _inFlight++;
      if (_inFlight > peakConcurrent) peakConcurrent = _inFlight;
      if (latency > Duration.zero) await Future<void>.delayed(latency);
      _inFlight--;
      if (refuse) {
        return http.Response(
          jsonEncode(<String, dynamic>{
            'ok': false,
            'error': <String, dynamic>{
              'code': 'not_shared',
              'message': 'That file is not shared with "Anyone with the link".',
            },
          }),
          400,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }
      return http.Response(
        jsonEncode(<String, dynamic>{
          'ok': true,
          'data': <String, dynamic>{
            'url': '/api/v1/forms/media/form_studio/abc123',
            'content_type': contentType,
          },
        }),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    }
    return http.Response(
      jsonEncode(<String, dynamic>{'ok': true, 'data': <String, dynamic>{}}),
      200,
      headers: <String, String>{'content-type': 'application/json'},
    );
  });

  bool get importedOnce => importCount == 1;
  bool get neverImported =>
      paths.every((String p) => !p.endsWith('/forms/media/import'));
}

Future<FormItem> _mount(
  WidgetTester tester,
  _Spy spy, {
  String? mediaUrl,
  String? mediaUrlB,
}) async {
  tester.view.physicalSize = const Size(1400, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final AppStore store =
      AppStore(api: ApiClient(baseUrl: 'http://stub', client: spy.client));
  store.adoptSession(orgRole: 'admin', name: 'QA', uid: '2');

  final FormItem item =
      FormItem('item-1', FormItemKind.imageBlock, title: 'Look at this');
  if (mediaUrl != null) item.mediaUrl = mediaUrl;
  if (mediaUrlB != null) item.mediaUrlB = mediaUrlB;

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: FormItemEditor(
            store: store,
            item: item,
            index: 0,
            onEdit: (VoidCallback mutate) => mutate(),
            onDuplicate: () {},
            onDelete: () {},
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return item;
}

/// Mounts [count] editors in ONE tree, which is what the designer does: its
/// `ReorderableListView.builder` runs with `shrinkWrap` and no lazy viewport,
/// so every card is constructed on the first frame and every prefill fires at
/// once. Returns the store, because the toasts it does and does not raise are
/// half of what is being asserted.
Future<AppStore> _mountForm(
  WidgetTester tester,
  _Spy spy, {
  int count = 1,
}) async {
  tester.view.physicalSize = const Size(1400, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final AppStore store =
      AppStore(api: ApiClient(baseUrl: 'http://stub', client: spy.client));
  store.adoptSession(orgRole: 'admin', name: 'QA', uid: '2');

  final List<FormItem> items = <FormItem>[
    for (int i = 0; i < count; i++)
      FormItem('item-$i', FormItemKind.imageBlock, title: 'Q$i')
        ..mediaUrl = _fanUrl(i),
  ];

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: Column(
            children: <Widget>[
              for (int i = 0; i < items.length; i++)
                FormItemEditor(
                  key: ValueKey<String>('item-${items[i].id}'),
                  store: store,
                  item: items[i],
                  index: i,
                  onEdit: (VoidCallback mutate) => mutate(),
                ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return store;
}

String _fanUrl(int i) => 'https://drive.google.com/file/d/1FANOUT${i}xxxxxxxxxxxxxxxx/view';

void main() {
  group('a file that omits ids still gets unique ones', () {
    // THE DEEPER HALF OF THE SAME BUG. Both real exports this was reported
    // against carry NO `id` on any item - 31 items in one, 6 in the other.
    // `fromJson` used to keep that empty string, and the designer keys each
    // editor `ValueKey('item-${it.id}')`, so every row shared one key.
    //
    // `debugChildrenHaveDuplicateKeys` is DEBUG-ONLY. In the release build that
    // production runs, duplicate keys do not throw - Flutter mis-matches
    // elements and one State ends up serving several items. Every per-item map
    // in that State then collides, so the Drive import scheduled for one
    // question CANCELLED the one scheduled for the question before it, and all
    // but the last stuck reading "Copying that Drive file into this app...".
    Map<String, dynamic> itemJson(String title) => <String, dynamic>{
          'kind': 'image_block',
          'title': title,
          'media_url': _drivePage,
        };

    test('items without ids are minted distinct ones', () {
      final List<FormItem> items = <FormItem>[
        for (int i = 0; i < 31; i++) FormItem.fromJson(itemJson('Q$i')),
      ];

      expect(items.map((FormItem i) => i.id).toSet().length, 31);
      expect(items.every((FormItem i) => i.id.isNotEmpty), isTrue);
    });

    test('an id the file DOES carry is kept', () {
      final FormItem it =
          FormItem.fromJson(<String, dynamic>{...itemJson('Q'), 'id': 'keep-me'});

      expect(it.id, 'keep-me', reason: 'a real id must round-trip untouched');
    });

    test('a whitespace id counts as absent', () {
      // `"id": " "` is not an identifier, and letting it through would
      // reintroduce the collision this exists to stop.
      final FormItem it =
          FormItem.fromJson(<String, dynamic>{...itemJson('Q'), 'id': '   '});

      expect(it.id.trim(), isNotEmpty);
      expect(it.id, isNot('   '));
    });

    test('a minted id is stable for the life of the item', () {
      // AN ID THAT MOVES IS THE SAME BUG IN A NEW COSTUME. The designer keys
      // each editor `ValueKey('item-$id')`, so an id regenerated on every read
      // would re-create the State on every rebuild - and every per-item map
      // inside it, including the pending Drive import. Minting belongs to the
      // PARSE, once, not to the getter.
      final FormItem it = FormItem.fromJson(itemJson('Q'));
      final String first = it.id;

      expect(it.id, first);
      expect(it.toJson()['id'], first,
          reason: 'and it must survive the save, or every save makes a new item');
    });

    test('sections and options get the same treatment', () {
      final List<FormSection> secs = <FormSection>[
        for (int i = 0; i < 5; i++)
          FormSection.fromJson(<String, dynamic>{'title': 'S$i'}),
      ];
      final List<FormOption> opts = <FormOption>[
        for (int i = 0; i < 5; i++)
          FormOption.fromJson(<String, dynamic>{'label': 'O$i'}),
      ];

      expect(secs.map((FormSection s) => s.id).toSet().length, 5,
          reason: "sections are keyed ValueKey('sec-\$id') too");
      expect(opts.map((FormOption o) => o.id).toSet().length, 5);
    });
  });


  testWidgets('a pre-filled Drive link is imported without being retyped', (
    WidgetTester tester,
  ) async {
    final _Spy spy = _Spy();
    final FormItem item = await _mount(tester, spy, mediaUrl: _drivePage);

    // Nothing has happened yet - the resolve is debounced.
    expect(spy.neverImported, isTrue);

    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    // Drain the success toast's own dismiss timer, which outlives the frame
    // and fails the test at teardown if it is still pending.
    await tester.pump(const Duration(seconds: 4));

    expect(spy.importedOnce, isTrue,
        reason: 'the link arrived by import, not by typing, and must still be '
            'copied into the app');
    expect(item.mediaUrl, '/api/v1/forms/media/form_studio/abc123',
        reason: 'the item must end up holding the app\'s own url');
  });

  testWidgets('the same holds for the B slot of a comparison', (
    WidgetTester tester,
  ) async {
    final _Spy spy = _Spy();
    final FormItem item = await _mount(tester, spy, mediaUrlB: _drivePage);

    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 4));

    expect(spy.importedOnce, isTrue);
    expect(item.mediaUrlB, '/api/v1/forms/media/form_studio/abc123');
  });

  testWidgets('a pre-filled Drive VIDEO link is imported too', (
    WidgetTester tester,
  ) async {
    final _Spy spy = _Spy()..contentType = 'video/mp4';
    final FormItem item = await _mount(tester, spy, mediaUrl: _driveVideo);

    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 4));

    expect(spy.importedOnce, isTrue);
    expect(item.mediaKind, 'video',
        reason: 'the server names the medium; the item must record it');
  });

  testWidgets('a direct image url is left alone - there is nothing to import', (
    WidgetTester tester,
  ) async {
    // Only the share hosts are importable; a direct file url renders as-is, and
    // the import route refuses it. Sending one would be a wasted round trip and
    // a toast the examiner cannot act on.
    final _Spy spy = _Spy();
    final FormItem item = await _mount(tester, spy, mediaUrl: _directImage);

    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    expect(spy.neverImported, isTrue);
    expect(item.mediaUrl, _directImage, reason: 'left exactly as it was');
  });

  testWidgets('an empty slot asks for nothing', (WidgetTester tester) async {
    final _Spy spy = _Spy();
    await _mount(tester, spy);

    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    expect(spy.neverImported, isTrue);
  });

  testWidgets('an already-imported url is not imported again', (
    WidgetTester tester,
  ) async {
    // Reopening a form must not re-fetch every picture in it.
    final _Spy spy = _Spy();
    await _mount(tester, spy,
        mediaUrl: '/api/v1/forms/media/form_studio/abc123');

    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    expect(spy.neverImported, isTrue);
  });

  testWidgets('a REFUSED automatic import says so, and offers the retry', (
    WidgetTester tester,
  ) async {
    // THE SLOT TAG IS A LABEL, NOT AN IDENTITY, and keying on it split the
    // writer from the reader. The prefill pass names the two media slots 'a'
    // and 'b'; the renderer names the same two 'main'/'output' (and 'Side A'/
    // 'Side B' on a comparison). So a refused automatic import recorded
    // '<id>:a' while `_mediaUrlRow` and `_mediaFailed` both looked up
    // '<id>:main', and the flag never matched: the plate went on reporting
    // "Copying that Drive file into this app..." forever, and neither
    // "Try again" nor "Copy into this app" ever appeared.
    //
    // That is the SAME dead end the prefill pass was added to cure, still
    // present on the commonest Drive failure there is - a file left shared
    // "Restricted" - and the only recourse left was an Upload nothing pointed
    // at. A link that was TYPED showed the notice correctly, which is the tell:
    // the two paths differ in nothing but the tag.
    final _Spy spy = _Spy()..refuse = true;
    await _mount(tester, spy, mediaUrl: _driveRestricted);

    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    expect(spy.importedOnce, isTrue, reason: 'it must have really tried');
    expect(
      find.textContaining('Could not copy that Drive file in automatically'),
      findsOneWidget,
      reason: 'a failure the examiner cannot see is a failure they cannot fix',
    );
    expect(find.text('Try again'), findsOneWidget);

    // Drain the failure toast's dismiss timer, or teardown fails on it.
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('a refusal is not re-run every time the form is opened', (
    WidgetTester tester,
  ) async {
    final _Spy first = _Spy()..refuse = true;
    await _mount(tester, first, mediaUrl: _driveReopened);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 4));
    expect(first.importCount, 1);

    // Leave the designer and come back: every card re-mounts, and the prefill
    // pass runs again from scratch.
    await tester.pumpWidget(const SizedBox.shrink());
    final _Spy again = _Spy()..refuse = true;
    await _mount(tester, again, mediaUrl: _driveReopened);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    expect(
      again.neverImported,
      isTrue,
      reason: 'a form of thirty unshared files would otherwise re-run thirty '
          'refused downloads, and re-toast thirty refusals, on every visit',
    );
    expect(
      find.textContaining('Could not copy that Drive file in automatically'),
      findsOneWidget,
      reason: 'remembering the refusal must not mean hiding it',
    );
  });

  testWidgets('opening a form does not fan out one download per media item', (
    WidgetTester tester,
  ) async {
    // `/forms/media/import` is a BLOCKING server-side download: it fetches the
    // Drive file with its own client, follows the redirects hop by hop and
    // buffers the body, so one request holds one worker for the whole transfer.
    // The designer builds every card on the first frame, so a form with twenty
    // media items used to fire twenty of these from a single frame's timers,
    // capped by nothing but the browser's per-origin limit - which is already
    // more than a worker pool. Opening a form is the commonest action in Form
    // Studio, and it does not need any of those bytes yet.
    const int cards = 8;
    final _Spy spy = _Spy()..latency = const Duration(seconds: 1);

    await _mountForm(tester, spy, count: cards);
    await tester.pump(const Duration(milliseconds: 500));
    for (int i = 0; i < cards; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    await tester.pumpAndSettle();

    expect(spy.importCount, cards,
        reason: 'every prefilled link is still imported - just not at once');
    expect(
      spy.peakConcurrent,
      lessThanOrEqualTo(2),
      reason: 'the fan-out has to be bounded, or a thirty-question form takes '
          'the whole worker pool - and every exam it is serving - hostage',
    );
  });

  testWidgets('a card closed mid-import spends nothing more and throws nothing', (
    WidgetTester tester,
  ) async {
    // THE QUEUE ADDS A SECOND PLACE THE WORK CAN BE SITTING when the card goes
    // away, so both have to survive it: the job re-checks `mounted` when its
    // turn finally comes, and the caller checks again when it returns. A
    // `setState` on a disposed State throws, and an import nobody is waiting
    // for is a worker held for nothing.
    final _Spy spy = _Spy()..latency = const Duration(seconds: 1);
    await _mountForm(tester, spy, count: 3);
    await tester.pump(const Duration(milliseconds: 500));
    expect(spy.importCount, 2, reason: 'two in flight, one still queued');

    // The examiner leaves the designer while they are running.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(spy.importCount, 2,
        reason: 'the queued one is dropped, not spent on a card that is gone');
  });

  testWidgets('a prefilled import lands without a toast of its own', (
    WidgetTester tester,
  ) async {
    // `Toaster` stacks rather than replaces, and its entries live 3200ms, so
    // one toast per item means a form covered by its own good news for several
    // seconds. A paste is one deliberate act and still gets acknowledged; a
    // prefill's acknowledgement is the picture appearing where the dead share
    // page was.
    final _Spy spy = _Spy();
    final AppStore store = await _mountForm(tester, spy, count: 3);

    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    expect(spy.importCount, 3, reason: 'all three were imported');
    expect(store.toaster.items, isEmpty,
        reason: 'and none of them announced it');
  });
}
