// A PASTED DRIVE LINK MUST WORK BY ITSELF, and must never turn a clip into a
// still.
//
// THE TWO DEFECTS THIS PINS.
//
//  1. A `drive.google.com/file/d/<id>/view` link is the VIEWER PAGE - it answers
//     `text/html`, so nothing could render it and the plate drew empty. The only
//     remedy offered was a button that copied the bytes into our own store,
//     which is an upload wearing a link's clothes. It is now rewritten into a
//     url that displays.
//
//  2. THE REWRITE TARGET DIFFERS BY MEDIUM, and picking wrong is worse than not
//     rewriting at all. Measured against real public files:
//
//       lh3.googleusercontent.com/d/<id>                   -> image/jpeg
//       drive.usercontent.google.com/download?id=<id>...   -> video/mp4
//
//     `lh3` answers `image/jpeg` for a VIDEO file too - a poster thumbnail - so
//     sending a clip there silently publishes it as a picture, which is exactly
//     how a Drive video reached a candidate as a dead 0:00 player. A Drive url
//     carries no extension, so the kind cannot be read off the string: the
//     designer probes the content type instead, and that is what these assert.
@TestOn('vm')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ethara_assessment/assessment/data/api_client.dart';
import 'package:ethara_assessment/assessment/domain/form_models.dart';
import 'package:ethara_assessment/assessment/screens/admin/form_item_editor.dart';

/// The real ids from the files this was verified against.
const String kImageId = '1dvYrRhY6NP9c--vg3_PSX4M5jG8E4kji';
const String kVideoId = '1A9qBxVtHCuE-o-5gi5GiHlwOPCA4ke3g';

void main() {
  group('the Drive file id comes out of every share shape', () {
    test('a /file/d/ view link', () {
      expect(
        driveFileId('https://drive.google.com/file/d/$kImageId/view?usp=sharing'),
        kImageId,
      );
    });

    test('a bare /file/d/ link with no query', () {
      expect(driveFileId('https://drive.google.com/file/d/$kVideoId/view'),
          kVideoId);
    });

    test('an /open?id= link', () {
      expect(driveFileId('https://drive.google.com/open?id=$kImageId'),
          kImageId);
    });

    test('a /uc?export=view&id= link', () {
      expect(
        driveFileId('https://drive.google.com/uc?export=view&id=$kImageId'),
        kImageId,
      );
    });

    test('a folder is NOT a file', () {
      // Rewriting a folder id would produce a confident 404. Refusing leaves
      // the examiner with a link that at least still opens in Drive.
      expect(driveFileId('https://drive.google.com/drive/folders/$kImageId'),
          isNull);
    });

    test('a Docs link is not a Drive FILE link', () {
      expect(
        driveFileId('https://docs.google.com/document/d/$kImageId/edit'),
        isNull,
      );
    });

    test('a truncated id is refused rather than rewritten', () {
      // The 10-character floor mirrors the server's `_drive_file_id`. A short
      // paste is a mistake, and a rewrite would hide it behind a 404.
      expect(driveFileId('https://drive.google.com/file/d/abc/view'), isNull);
    });

    test('a lookalike host is refused', () {
      // Anchored, so this is not the security boundary but it must not disagree
      // with the one on the server.
      expect(
        driveFileId('https://drive.google.com.evil.test/file/d/$kImageId/view'),
        isNull,
      );
      expect(driveFileId('https://notdrive.google.com/file/d/$kImageId/view'),
          isNull);
    });
  });

  group('a Drive link is handed to the SERVER, not rewritten here', () {
    const String share =
        'https://drive.google.com/file/d/$kImageId/view?usp=sharing';

    test('it is recognised as something the importer accepts', () {
      // There is no client-side rewrite any more, and this is why. Measured in
      // Chrome against these same public files:
      //
      //   drive.usercontent.google.com/download  subresource -> 403, no CORS
      //   lh3.googleusercontent.com/d/<id>       subresource -> 200 image/jpeg
      //
      // `curl` gets 200 with `ACAO: *` from BOTH, which is what made a rewrite
      // to the download host look correct while it silently failed in every
      // browser - and had it succeeded, a `<video>` pointed there would not have
      // played either. `lh3` is readable but calls a VIDEO `image/jpeg` (it
      // serves the poster frame), so it cannot tell the two media apart.
      //
      // The server has no such limit: it fetches with its own client, sees the
      // real `video/mp4` and stores the bytes. So the only thing decided here is
      // WHETHER to hand the link over.
      expect(isImportableMediaSource(share), isTrue);
    });

    test('a folder is not handed over', () {
      expect(
        isImportableMediaSource(
            'https://drive.google.com/drive/folders/$kImageId'),
        isFalse,
      );
    });

    test('an ordinary direct media url is left alone', () {
      // It already works as a link, so importing it would be a pointless round
      // trip and a surprise change to the field.
      expect(isImportableMediaSource('https://example.com/pic.png'), isFalse);
    });
  });

  group('the content-type probe decides the kind, and fails closed', () {
    ApiClient clientAnswering(int status, Map<String, String> headers) =>
        ApiClient(
          client: MockClient(
            (http.Request _) async => http.Response('', status,
                headers: headers),
          ),
          baseUrl: 'http://localhost:8069',
        );

    test('video/mp4 reads as a video', () async {
      final ApiClient api =
          clientAnswering(200, <String, String>{'content-type': 'video/mp4'});
      expect(await api.probeMediaKind('https://x.test/a'), 'video');
    });

    test('image/jpeg reads as an image, charset and all', () async {
      final ApiClient api = clientAnswering(
          200, <String, String>{'content-type': 'image/jpeg; charset=binary'});
      expect(await api.probeMediaKind('https://x.test/a'), 'image');
    });

    test('text/html is NOT media - the Drive viewer page', () async {
      final ApiClient api = clientAnswering(
          200, <String, String>{'content-type': 'text/html; charset=utf-8'});
      expect(await api.probeMediaKind('https://x.test/a'), isNull);
    });

    test('a missing content type answers nothing', () async {
      final ApiClient api = clientAnswering(200, <String, String>{});
      expect(await api.probeMediaKind('https://x.test/a'), isNull);
    });

    test('a 404 answers nothing', () async {
      final ApiClient api = clientAnswering(
          404, <String, String>{'content-type': 'image/jpeg'});
      expect(await api.probeMediaKind('https://x.test/a'), isNull);
    });

    test('a thrown request answers nothing rather than propagating', () async {
      // This is the CORS case on web: the browser refuses and package:http
      // reports a bare ClientException with no detail. It must not escape into
      // the designer, and it must not be mistaken for an answer.
      final ApiClient api = ApiClient(
        client: MockClient((http.Request _) async =>
            throw http.ClientException('blocked')),
        baseUrl: 'http://localhost:8069',
      );
      expect(await api.probeMediaKind('https://x.test/a'), isNull);
    });

    test('a url with no scheme is not probed at all', () async {
      bool called = false;
      final ApiClient api = ApiClient(
        client: MockClient((http.Request _) async {
          called = true;
          return http.Response('', 200);
        }),
        baseUrl: 'http://localhost:8069',
      );
      expect(await api.probeMediaKind('drive.google.com/file/d/x'), isNull);
      expect(called, isFalse, reason: 'a bare host is not a fetchable url');
    });
  });

  group('the probed kind survives a Duplicate', () {
    test('media_kind round-trips through toJson/fromJson', () {
      // `FormItem` has no `copyWith`: Duplicate copies an item by round-tripping
      // it through JSON, so a key present in one half and missing from the other
      // is silently lost - and a lost kind means the copy publishes as the wrong
      // medium.
      final FormItem it = FormItem('i1', FormItemKind.videoBlock)
        ..mediaUrl = 'https://drive.usercontent.google.com/download?id=x'
        ..mediaKind = 'video';

      final FormItem copy = FormItem.fromJson(it.toJson());
      expect(copy.mediaKind, 'video');
      expect(copy.mediaUrl, it.mediaUrl);
    });

    test('an unprobed item carries an empty kind, not a guess', () {
      final FormItem it = FormItem('i1', FormItemKind.imageBlock)
        ..mediaUrl = 'https://example.com/p.png';
      expect(it.mediaKind, '');
      // And the key is omitted entirely rather than sent as '', so the server
      // sees "not established" and falls back to its own url test.
      expect(it.toJson().containsKey('media_kind'), isFalse);
      expect(FormItem.fromJson(it.toJson()).mediaKind, '');
    });
  });

  group('a web PAGE is named as one', () {
    test("the url from the bug report is recognised as a page", () {
      // Reported as "media urls do not work", tested with this. It answers
      // text/html - it is the photo's PAGE, not the photo, so no image code
      // could ever have rendered it. Saying so is the fix.
      expect(
        looksLikeWebPageUrl(
            'https://unsplash.com/photos/a-black-and-white-photo-of-the-ocean-MmvZ5_y3uuM'),
        isTrue,
      );
    });

    test('the same site serving an actual image file is NOT a page', () {
      expect(
        looksLikeWebPageUrl(
            'https://images.unsplash.com/photo-1439405326854-014607f694d7?w=1200'),
        isFalse,
      );
    });

    test('an extension behind a query string still reads as a file', () {
      expect(looksLikeWebPageUrl('https://cdn.test/clip.mp4?sig=abc'), isFalse);
    });

    test('a Drive link is left to the rewrite, not called a page', () {
      expect(
        looksLikeWebPageUrl(
            'https://drive.google.com/file/d/$kImageId/view'),
        isFalse,
      );
    });

    test('an ordinary no-CORS image host is not called a page', () {
      // The honest case for the `<img>` element path: a real image file whose
      // host sends no CORS headers. Mislabelling it a page would send the
      // examiner off to hunt for a different url they do not need.
      expect(looksLikeWebPageUrl('https://www.gstatic.com/webp/gallery/1.jpg'),
          isFalse);
    });
  });
}
