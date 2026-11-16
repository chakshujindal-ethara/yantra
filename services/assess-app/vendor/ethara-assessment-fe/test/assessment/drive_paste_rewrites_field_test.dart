// PASTING A DRIVE LINK, THROUGH THE REAL WIDGET, IN EVERY SLOT THAT TAKES ONE.
//
// WHY THIS EXISTS AND THE OTHER DRIVE TESTS DID NOT CATCH THE BUG.
// `drive_share_link_test.dart` asserts the HELPERS and `form_media_url_test.dart`
// asserts the notice gate. Both passed while the feature was visibly broken in
// the browser, because neither drives `onChanged` on a real card and then reads
// the FIELD.
//
// Three defects were live behind that gap:
//
//   1. `FormTextInput` handed its value to `TextFormField.initialValue`, read
//      once in `initState`, so a programmatic rewrite never reached the box.
//   2. `_slotValue` mapped the second slot as `'output'`/`'b'`, but `_mediaPair`
//      passes its display label `'Side B'` - so the stale-answer guard compared
//      Side B's answer against Side A's url and dropped every rewrite on the
//      right-hand half of a comparison.
//   3. THE REWRITE TARGET WAS UNREACHABLE FROM A BROWSER. The design probed
//      `drive.usercontent.google.com` with a `HEAD` and rewrote the field to it.
//      Verified with `curl` that host answers 200 with `Access-Control-Allow-
//      Origin: *`; verified in Chrome it answers a subresource request with 403
//      and no CORS header at all. So the probe always failed closed and nothing
//      was ever rewritten - and had it succeeded, a `<video>` pointed there
//      would not have played either. The medium is now established SERVER-side,
//      where the true `video/mp4` is visible, by the import route.
//
// These tests go through `enterText` on the rendered card, which is the only
// path that exercises the debounce, the round trip, the guard and the field
// together.
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

const String kImageId = '1dvYrRhY6NP9c--vg3_PSX4M5jG8E4kji';
const String kShare = 'https://drive.google.com/file/d/$kImageId/view';

/// Where the import route puts the bytes: this app's own media proxy.
const String kStored = '/api/v1/forms/media/form_studio/deadbeef.jpg';
const String kStoredMp4 = '/api/v1/forms/media/form_studio/deadbeef.mp4';

/// A live store whose import route answers with [url] and [contentType],
/// counting how many times it was called.
///
/// LIVE ON PURPOSE: `importFormMediaDetailed` refuses on a seed store, which is
/// the same reason the old "Copy into this app" button did.
({AppStore store, int Function() calls, List<String> urls}) _storeImporting({
  required String url,
  required String contentType,
  int status = 200,
  String? errorCode,
}) {
  int n = 0;
  final List<String> asked = <String>[];
  final AppStore store = AppStore(
    api: ApiClient(
      client: MockClient((http.Request req) async {
        if (!req.url.path.contains('/forms/media/import')) {
          return http.Response(
              jsonEncode(<String, dynamic>{'ok': true, 'data': <String, dynamic>{}}),
              200,
              headers: <String, String>{'content-type': 'application/json'});
        }
        n++;
        asked.add((jsonDecode(req.body)['url'] ?? '').toString());
        if (errorCode != null) {
          return http.Response(
            jsonEncode(<String, dynamic>{
              'ok': false,
              'error': <String, dynamic>{
                'code': errorCode,
                'message': 'That file did not come back as an image or video.',
              },
            }),
            status,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }
        return http.Response(
          jsonEncode(<String, dynamic>{
            'ok': true,
            'data': <String, dynamic>{
              'url': url,
              'content_type': contentType,
              'storage': 's3',
            },
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }),
      baseUrl: 'http://localhost:8069',
    ),
  );
  store.source = DataSource.live;
  return (store: store, calls: () => n, urls: asked);
}

Future<void> _pump(WidgetTester t, AppStore store, FormItem it) async {
  t.view.physicalSize = const Size(1600, 2600);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: ThemeData.dark(),
    home: Scaffold(
      body: SingleChildScrollView(
        child: FormItemEditor(
          store: store,
          item: it,
          index: 0,
          showDragHandle: false,
          onEdit: (VoidCallback mutate) => mutate(),
          onDuplicate: () {},
          onDelete: () {},
        ),
      ),
    ),
  ));
  await t.pump();
}

/// The field under [hint]. Slots are told apart by their hint, not by order -
/// a card has several inputs and `.first` silently picked the title.
///
/// ONLY VALID BEFORE THE BOX HAS CONTENT: a hint stops rendering once text is
/// entered, so this cannot be re-run after a paste to read the result. Use
/// [_textIn] with the finder captured beforehand.
Finder _fieldWithHint(String hint) =>
    find.ancestor(of: find.text(hint), matching: find.byType(TextFormField));

/// What a media field currently DISPLAYS, or null when the field is not on
/// screen at all.
///
/// KEYED, NOT HINTED. A `Finder` is lazy - it re-runs on every use - and a hint
/// stops rendering the moment the box has text, so a hint-based finder cannot
/// read a field back after a paste. `FormTextInput` keys itself
/// `fti-media-<slot>-<item id>`, which is stable across a value change.
///
/// And not `find.text`: an `EditableText` renders through its controller, so a
/// rendered `Text` carrying the value is not what proves the box was updated -
/// which is precisely the bug this file exists to pin.
///
/// NULLABLE ON PURPOSE. A successful import leaves this app's own
/// `/api/v1/forms/media/...` url in the slot, and `_mediaUrlRow` then opens in
/// UPLOAD mode by default - correctly, the media is now an uploaded file - so
/// the Link input is legitimately gone. Null therefore means "the app treats
/// this as its own file", which for the success case is the outcome, not a
/// failure to read the widget.
String? _linkFieldText(WidgetTester t, String slot, FormItem it) {
  final Finder box = find.descendant(
    of: find.byKey(ValueKey<String>('fti-media-$slot-${it.id}')),
    matching: find.byType(EditableText),
  );
  if (box.evaluate().isEmpty) return null;
  return t.widget<EditableText>(box).controller.text;
}

/// Paste, let the debounce elapse, let the import land. The trailing pump drains
/// the toast timer so the test does not fail on a pending timer it did not own.
Future<void> _paste(WidgetTester t, Finder field, String url) async {
  await t.enterText(field, url);
  await t.pump();
  await t.pump(const Duration(milliseconds: 600));
  await t.pump();
  await t.pump(const Duration(seconds: 4));
}

void main() {
  testWidgets('an imageBlock imports on paste, and the FIELD shows the result',
      (WidgetTester t) async {
    final ({AppStore store, int Function() calls, List<String> urls}) h =
        _storeImporting(url: kStored, contentType: 'image/jpeg');
    final FormItem it = formNewItem(FormItemKind.imageBlock);
    await _pump(t, h.store, it);

    await _paste(t, _fieldWithHint('Image URL (https://…)'), kShare);

    expect(it.mediaUrl, kStored);
    expect(it.mediaKind, 'image');
    expect(h.calls(), 1, reason: 'one paste is one import, not one per char');
    expect(h.urls.single, kShare,
        reason: 'the server is handed the share link, and resolves it itself');
    // THE HALF THE HELPER TESTS COULD NOT SEE. The share page must be gone from
    // the card - it is what the examiner was left staring at while the model
    // held something else, and it is what the notice keyed off.
    expect(find.text(kShare), findsNothing);
    expect(_linkFieldText(t, 'main', it), isNull,
        reason: 'imported media belongs to this app, so the row shows Upload');
    expect(find.text('Copy into this app'), findsNothing,
        reason: 'the whole point: no second click is offered or needed');
  });

  testWidgets('a videoBlock takes its kind from the SERVER, not the url shape',
      (WidgetTester t) async {
    // The whole reason the medium is decided server-side: a browser reading
    // Drive sees `image/jpeg` for this file (lh3 serves a poster frame) and
    // would publish the clip as a still.
    final ({AppStore store, int Function() calls, List<String> urls}) h =
        _storeImporting(url: kStoredMp4, contentType: 'video/mp4');
    final FormItem it = formNewItem(FormItemKind.videoBlock);
    await _pump(t, h.store, it);

    await _paste(t, _fieldWithHint('Video URL (https://…)'), kShare);

    expect(it.mediaUrl, kStoredMp4);
    expect(it.mediaKind, 'video');
    expect(it.mediaUrl, isNot(contains('drive.')),
        reason: 'the exam must not depend on a share link at sitting time');
  });

  testWidgets('an Audio block keeps its DECLARED kind through an import',
      (WidgetTester t) async {
    // The server still reads the file for itself at publish; the item carries
    // what the examiner chose, so the designer keeps calling it Audio.
    final ({AppStore store, int Function() calls, List<String> urls}) h =
        _storeImporting(url: kStoredMp4, contentType: 'video/mp4');
    final FormItem it = formNewItem(FormItemKind.videoBlock)
      ..mediaKind = 'audio';
    await _pump(t, h.store, it);

    await _paste(t, _fieldWithHint('Audio URL (https://…)'), kShare);

    expect(it.mediaUrl, kStoredMp4, reason: 'the import itself still runs');
    expect(it.mediaKind, 'audio');
    expect(formItemLabel(it), 'Audio');
  });

  testWidgets('SIDE B of a comparison imports too, and does not touch Side A',
      (WidgetTester t) async {
    // The regression `_slotValue` had: 'Side B' matched no case, so the guard
    // compared Side B's answer against Side A's url and dropped the rewrite.
    final ({AppStore store, int Function() calls, List<String> urls}) h =
        _storeImporting(url: kStored, contentType: 'image/jpeg');
    final FormItem it = formNewItem(FormItemKind.comparePair);
    it.mediaUrl = 'https://cdn.example.com/side-a.png';
    await _pump(t, h.store, it);

    final Finder both = _fieldWithHint('Image or video URL (https://…)');
    expect(both, findsNWidgets(2));
    await _paste(t, both.last, kShare);

    expect(it.mediaUrlB, kStored, reason: 'Side B must be imported');
    expect(it.mediaUrl, 'https://cdn.example.com/side-a.png',
        reason: 'Side A must be left exactly as it was');
  });

  testWidgets('an image annotation slot imports as well',
      (WidgetTester t) async {
    final ({AppStore store, int Function() calls, List<String> urls}) h =
        _storeImporting(url: kStored, contentType: 'image/jpeg');
    final FormItem it = formNewItem(FormItemKind.imageAnnotation);
    await _pump(t, h.store, it);

    await _paste(t, _fieldWithHint('Image URL (https://…)'), kShare);

    expect(it.mediaUrl, kStored);
  });

  testWidgets('a server refusal leaves the pasted url exactly as typed',
      (WidgetTester t) async {
    // FAILS CLOSED. An unshared Drive file answers the sign-in page, the server
    // says so, and the field keeps the link - the notice and its button are
    // still there to try again.
    final ({AppStore store, int Function() calls, List<String> urls}) h =
        _storeImporting(
      url: '',
      contentType: '',
      status: 422,
      errorCode: 'not_media',
    );
    final FormItem it = formNewItem(FormItemKind.imageBlock);
    await _pump(t, h.store, it);

    await _paste(t, _fieldWithHint('Image URL (https://…)'), kShare);

    expect(it.mediaUrl, kShare, reason: 'a refusal means no change');
    expect(_linkFieldText(t, 'main', it), kShare,
        reason: 'the examiner keeps what they typed, and can retry');

    // AND THE MANUAL CONTROL COMES BACK. Suppressing the offer for every Drive
    // link would turn a failed import into a dead end: the field holds a share
    // page that cannot render, and nothing on screen would do anything about it.
    // Worded as a failure, not as a fresh opportunity - the examiner has just
    // seen the app try and fail, so "this app can copy that file" would
    // contradict what they watched happen.
    expect(find.text('Try again'), findsOneWidget,
        reason: 'the automatic attempt failed - a manual retry is the only route');
    expect(find.textContaining('Could not copy that Drive file'), findsOneWidget);
    expect(find.textContaining('can copy that file'), findsNothing,
        reason: 'that wording claims no attempt was made');
  });

  testWidgets('NOTHING IS OFFERED WHILE THE IMPORT IS STILL IN FLIGHT',
      (WidgetTester t) async {
    // THE REPORTED DEFECT ITSELF: "I see the notice and Copy into this app
    // render and then it is imported to S3 and the right behaviour happens. We
    // should not show it - it misleads the end user."
    //
    // The window is real and this test lives inside it: the paste is entered, a
    // frame is pumped, and the debounce is deliberately NOT elapsed - so the
    // field holds the share page and the import has not even started. Every
    // earlier test asserted the end state and so passed while this window was
    // showing a false affordance.
    final ({AppStore store, int Function() calls, List<String> urls}) h =
        _storeImporting(url: kStored, contentType: 'image/jpeg');
    final FormItem it = formNewItem(FormItemKind.imageBlock);
    await _pump(t, h.store, it);

    await t.enterText(_fieldWithHint('Image URL (https://…)'), kShare);
    await t.pump();

    expect(h.calls(), 0, reason: 'still inside the debounce - nothing sent yet');
    expect(_linkFieldText(t, 'main', it), kShare,
        reason: 'the share page is what is on screen during this window');
    expect(find.text('Copy into this app'), findsNothing,
        reason: 'THE DEFECT: an offer to do what is already about to be done');
    expect(find.textContaining('can copy that file'), findsNothing,
        reason: 'THE DEFECT: the notice half of the same false affordance');

    // Let it finish so the test owns no pending timers.
    await t.pump(const Duration(milliseconds: 600));
    await t.pump();
    await t.pump(const Duration(seconds: 4));
    expect(it.mediaUrl, kStored, reason: 'and it still lands, as before');
  });

  testWidgets('a fresh paste retires a previous failure', (WidgetTester t) async {
    // The retry offer is stateful, so it has to expire. Left set, a link that
    // failed would keep its "Try again" after the examiner replaced it with a
    // different url - pointing the retry at media that is no longer in the box.
    final ({AppStore store, int Function() calls, List<String> urls}) h =
        _storeImporting(
      url: '',
      contentType: '',
      status: 422,
      errorCode: 'not_media',
    );
    final FormItem it = formNewItem(FormItemKind.imageBlock);
    await _pump(t, h.store, it);

    final Finder field = _fieldWithHint('Image URL (https://…)');
    await _paste(t, field, kShare);
    expect(find.text('Try again'), findsOneWidget, reason: 'the failure showed');

    // A plain url this time: not importable at all, so nothing may be offered.
    await t.enterText(
        find.descendant(
          of: find.byKey(ValueKey<String>('fti-media-main-${it.id}')),
          matching: find.byType(EditableText),
        ),
        'https://images.example.com/photo.jpg');
    await t.pump();

    expect(find.text('Try again'), findsNothing,
        reason: 'the old verdict was about a url that is gone');
    expect(find.text('Copy into this app'), findsNothing);
  });

  testWidgets('a non-Drive url is never sent to the importer',
      (WidgetTester t) async {
    // A plain third-party image url already works as a link, and copying it
    // would be a pointless round trip plus a surprise change to the field.
    final ({AppStore store, int Function() calls, List<String> urls}) h =
        _storeImporting(url: kStored, contentType: 'image/jpeg');
    final FormItem it = formNewItem(FormItemKind.imageBlock);
    await _pump(t, h.store, it);

    const String plain = 'https://images.example.com/photo-1234.jpg';
    await _paste(t, _fieldWithHint('Image URL (https://…)'), plain);

    expect(h.calls(), 0);
    expect(it.mediaUrl, plain);
  });
}
