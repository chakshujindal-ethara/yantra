// A PASTED MEDIA URL HAS TO REACH THE RIGHT WIDGET, in every slot.
//
// THE REPORTED DEFECT. "Media URLs still do not work (like google drive, other
// urls) but only works for Image Address" - Chrome's *Copy image address*, i.e.
// a direct file URL from a host that happens to send CORS headers. Everything
// else drew a dead plate.
//
// Two halves, and this file pins the one a VM test can see. `_looksImage` was
// the only thing deciding image-vs-video in the designer, and it tested the
// extension of the whole URL string, so a YouTube link, a Vimeo link and
// `clip.mp4?sig=abc` were all sent to `Image.network` - which mounts an element
// with nothing to decode: no error, no frame, a plate that looks like the app
// is broken. `VideoPlate` could already embed YouTube and Vimeo through the
// host's own player; only `videoBlock` ever reached it, so the three other
// media-carrying kinds could not show a hosted clip at all.
//
// NOT COVERED HERE, AND SAID PLAINLY: the CORS half. Handing the plate
// `WebHtmlElementStrategy.fallback` is what lets a no-CORS host render at all,
// and that flag is INERT on the VM (`_network_image_io.dart` stores it and
// never reads it). It can only be verified in a browser.
//
// On the VM `VideoPlate` resolves to `video_plate_stub.dart`, which renders
// `MissingVideo` - so "did this take the video branch" is exactly what a VM
// test can assert, and that is the assertion below.
@TestOn('vm')
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/domain/form_models.dart';
import 'package:ethara_assessment/assessment/screens/admin/form_item_editor.dart';
import 'package:ethara_assessment/assessment/screens/exam/video_plate.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';

const String _yt = 'https://www.youtube.com/watch?v=dQw4w9WgXcQ';
const String _signedClip = 'https://cdn.example.com/clip.mp4?sig=abc';
const String _drivePage =
    'https://drive.google.com/file/d/1dvYrRhY6NP9c--vg3_PSX4M5jG8E4kji/view';
const String _driveDirect =
    'https://drive.google.com/uc?export=view&id=1dvYrRhY6NP9c--vg3_PSX4M5jG8E4kji';

Future<void> _pump(
  WidgetTester tester,
  FormItemKind kind, {
  String? mediaUrl,
  String? mediaUrlB,
}) async {
  tester.view.physicalSize = const Size(1400, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final FormItem item = FormItem('item-1', kind, title: 'Look at this');
  if (mediaUrl != null) item.mediaUrl = mediaUrl;
  if (mediaUrlB != null) item.mediaUrlB = mediaUrlB;

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: FormItemEditor(
            store: AppStore(),
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
}

void main() {
  group('a hosted clip reaches the player in every slot', () {
    // THE THREE KINDS THAT COULD NOT SHOW A HOSTED CLIP AT ALL.
    testWidgets('an imageBlock carrying a YouTube link plays it', (
      WidgetTester tester,
    ) async {
      await _pump(tester, FormItemKind.imageBlock, mediaUrl: _yt);

      expect(find.byType(MissingVideo), findsOneWidget,
          reason: 'a YouTube link must reach VideoPlate, not Image.network');
      expect(find.byType(Image), findsNothing);
    });

    testWidgets('a promptWriting stimulus carrying a YouTube link plays it', (
      WidgetTester tester,
    ) async {
      await _pump(tester, FormItemKind.promptWriting, mediaUrl: _yt);

      expect(find.byType(MissingVideo), findsOneWidget);
    });

    testWidgets('an A/B pair plays a clip on either side', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        FormItemKind.comparePair,
        mediaUrl: _yt,
        mediaUrlB: 'https://vimeo.com/123456789',
      );

      expect(find.byType(MissingVideo), findsNWidgets(2));
    });

    // THE SIGNED-CDN SHAPE, which is a direct file and still failed: the
    // extension sits behind the query string.
    testWidgets('a signed .mp4 URL plays', (WidgetTester tester) async {
      await _pump(tester, FormItemKind.imageBlock, mediaUrl: _signedClip);

      expect(find.byType(MissingVideo), findsOneWidget);
    });
  });

  group('a still is still a still', () {
    testWidgets('an imageBlock with a .png draws an image, not a player', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        FormItemKind.imageBlock,
        mediaUrl: 'https://cdn.example.com/plate.png',
      );

      expect(find.byType(MissingVideo), findsNothing);
      expect(find.byType(Image), findsWidgets);
    });

    // A `videoBlock` is a clip BY DECLARATION. Its URL may have no extension
    // (an uploaded file, a Drive import), and it must not fall back to a still
    // just because the classifier cannot prove it is a video.
    testWidgets('a videoBlock plays an extensionless URL', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        FormItemKind.videoBlock,
        mediaUrl: '/api/v1/forms/media/form_studio/deadbeef',
      );

      expect(find.byType(MissingVideo), findsOneWidget);
    });
  });

  // THE BUTTON THAT WAS HIDDEN FROM THE URL THAT NEEDED IT.
  //
  // "Copy into this app" used to be gated on `mediaShareLinkWarning != null`,
  // which conflated two different questions: is this a share page, and can the
  // server copy it. So `drive.google.com/uc?export=view&id=...` - importable,
  // and raising no warning because it does serve real bytes - offered no button
  // at all, while also being a URL a browser will not read cross-origin.
  group('the import offer follows what the server can fetch', () {
    testWidgets('A DRIVE LINK OFFERS NOTHING - THE APP IMPORTS IT ITSELF', (
      WidgetTester tester,
    ) async {
      // THE DEFECT THIS PINS, reported as "it misleads the end user by showing
      // it unnecessarily". A Drive file link is imported automatically on paste,
      // but the notice and its button were gated on the url's SHAPE alone - so
      // they rendered for the length of the debounce plus the round trip, on top
      // of an import already in flight, and then vanished when it landed. An
      // offer to do what is already being done, withdrawn before it can be
      // clicked, makes a working flow look broken and invites a duplicate copy
      // of the same file.
      //
      // This test would have passed on the broken build too, if it only asserted
      // the end state - the whole complaint is about the window BEFORE the
      // import resolves, which is exactly what a pump with no network does: the
      // store here is not live, so no import can ever complete and the field
      // still holds the share page. Nothing may be offered in that state.
      await _pump(tester, FormItemKind.imageBlock, mediaUrl: _drivePage);

      expect(find.textContaining('Google Drive share page'), findsNothing);
      expect(find.text('Copy into this app'), findsNothing,
          reason: 'the app is importing it - offering the same action is a lie');
      expect(find.textContaining('can copy that file'), findsNothing,
          reason: 'the notice is the other half of the same false affordance');
    });

    testWidgets('a Drive DIRECT link is auto-imported too, so it also stays '
        'quiet', (WidgetTester tester) async {
      // ALL THREE DRIVE SHAPES ARE AUTO-IMPORTED. `driveFileId` matches
      // `/file/d/`, `/open?id=` AND `/uc?export=view&id=` - verified against the
      // function, not assumed from the share url an examiner usually pastes - so
      // `_resolveShareLink` fires for every one of them and the manual offer is
      // suppressed for every one of them. The suppression gate reads
      // `driveFileId(value) != null`, which is exactly this set, so this test and
      // the one above must agree.
      await _pump(tester, FormItemKind.imageBlock, mediaUrl: _driveDirect);

      expect(find.text('Copy into this app'), findsNothing,
          reason: 'auto-imported, so a manual offer duplicates it');
      expect(find.textContaining('share page'), findsNothing,
          reason: 'it serves real bytes - there is nothing to warn about');
    });

    testWidgets('a DROPBOX share link keeps its offer - nothing auto-imports it',
        (WidgetTester tester) async {
      // THE OTHER SIDE OF THE LINE, and the reason the gate is not simply
      // `isImportableMediaSource`. Only Drive is auto-imported; Dropbox,
      // OneDrive and SharePoint links are importable but nothing fetches them on
      // paste, so the manual button is their ONLY route and suppressing it would
      // turn a fixable link into a dead end.
      await _pump(
        tester,
        FormItemKind.imageBlock,
        mediaUrl: 'https://www.dropbox.com/s/abc/pic.png?dl=0',
      );

      expect(find.text('Copy into this app'), findsOneWidget,
          reason: 'importable, and no automatic import will ever run for it');
    });

    testWidgets('an ordinary CDN link offers nothing to copy', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        FormItemKind.imageBlock,
        mediaUrl: 'https://cdn.example.com/plate.png',
      );

      expect(find.text('Copy into this app'), findsNothing);
    });
  });

  // The allow-list the button is gated on, as a unit - it mirrors the server's
  // and the server re-checks every hop, so this is a convenience test, not a
  // security one. The lookalike cases are here because a substring match would
  // offer the button for a host the server will refuse, which reads to the
  // examiner as the feature being broken.
  group('importable sources', () {
    for (final String url in <String>[
      _drivePage,
      _driveDirect,
      'https://drive.google.com/open?id=1dvYrRhY6NP9c--vg3_PSX4M5jG8E4kji',
      'https://www.dropbox.com/s/abc/pic.png?dl=0',
      'https://www.dropbox.com/scl/fi/abc/pic.png?rlkey=x',
      'https://1drv.ms/i/s!Abc',
      'https://onedrive.live.com/?id=abc',
      'https://acme.sharepoint.com/:i:/g/abc',
      'https://acme.sharepoint.com/:v:/g/abc',
    ]) {
      test('$url can be copied', () {
        expect(isImportableMediaSource(url), isTrue);
      });
    }

    for (final String url in <String>[
      '',
      '   ',
      'https://cdn.example.com/plate.png',
      'https://acme.sharepoint.com/sites/team',
      'https://dropbox.com.evil.test/s/abc/x.png',
      'https://evil.test/?u=https://www.dropbox.com/s/a/x.png',
      '/api/v1/forms/media/form_studio/deadbeef.png',
    ]) {
      test('${url.isEmpty ? '(empty)' : url} cannot', () {
        expect(isImportableMediaSource(url), isFalse);
      });
    }
  });
}
