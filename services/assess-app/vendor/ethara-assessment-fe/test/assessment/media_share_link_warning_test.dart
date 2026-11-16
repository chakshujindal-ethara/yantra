// A SHARE PAGE IS NOT A MEDIA FILE.
//
// WHAT HAPPENED. An examiner pasted a Google Drive link into an image item:
//
//     https://drive.google.com/file/d/1dvYr.../view
//
// That URL answers `content-type: text/html` - it is Drive's viewer page, not
// the picture. `Image.network` decodes nothing from it, so the plate rendered
// "Could not load that image URL". True, but it never said WHY, and the
// natural next move is to paste the same link again. It read as Form Studio
// being broken when nothing was broken at all.
//
// The warning names the mistake and the fix in one line. These tests pin the
// hosts it recognises, and - just as importantly - that it stays QUIET for
// ordinary URLs, because a false positive on a working link would train
// examiners to ignore it.
//
// WHAT CHANGED, AND WHY DRIVE IS NO LONGER WARNED ABOUT. A Drive FILE link is
// now IMPORTED on paste (`_resolveShareLink` -> `/forms/media/import`), so by
// the time a warning would be drawn the field holds this app's own media url,
// not a share page. Warning about a link the app has already dealt with is
// noise.
//
// AND WHY IT IS AN IMPORT RATHER THAN A URL REWRITE. Drive cannot be rewritten
// client-side: `drive.usercontent.google.com` answers a browser subresource
// request with 403 and no CORS header (curl gets 200 with `ACAO: *`, which is
// what made an earlier rewrite look correct), and `lh3.googleusercontent.com` -
// the one host a browser can read - reports `image/jpeg` even for a video,
// because it serves the poster frame. Only the server sees the true type.
// Dropbox, OneDrive and SharePoint still warn: same conclusion, reached without
// needing the measurement.
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/screens/admin/form_item_editor.dart';

void main() {
  group('share pages are called out', () {
    test('the exact Drive link that caused this is handled, not warned about',
        () {
      // It used to warn and offer a copy button. The paste now triggers that
      // same copy by itself, so a warning here would be telling the examiner to
      // fix something the app has already handled - see `_resolveShareLink`.
      const String url =
          'https://drive.google.com/file/d/1dvYrRhY6NP9c--vg3_PSX4M5jG8E4kji/view';
      expect(mediaShareLinkWarning(url), isNull);
      // And it must still be recognised as something the importer accepts, or
      // the paste would do nothing at all.
      expect(isImportableMediaSource(url), isTrue);
    });

    test('a Jumpshare share page is offered the copy, a lookalike is not', () {
      expect(
        isImportableMediaSource('https://jumpshare.com/s/IOi4385ylQYXJhakspaA'),
        isTrue,
      );
      expect(
        isImportableMediaSource('https://jumpshare.com.evil.test/s/abc'),
        isFalse,
      );
    });

    test('a Drive link we cannot pull a file id out of still warns', () {
      // A folder, or a truncated paste. There is nothing to rewrite, so the
      // examiner does need telling - and the advice names the shape rather than
      // blaming the host.
      final String? warning = mediaShareLinkWarning(
          'https://drive.google.com/drive/folders/1dvYrRhY6NP9c--vg3');
      expect(warning, isNotNull);
      expect(warning, contains('not to a single file'));
    });

    test('Google Docs still warns, in any casing', () {
      // Docs is not Drive and has no rewrite: a Doc is never a stored image
      // file, so the honest advice is to export the picture and upload it.
      final String? warning =
          mediaShareLinkWarning('https://docs.google.com/document/d/abc/edit');
      expect(warning, isNotNull);
      expect(warning, contains('Upload'));
      expect(
        mediaShareLinkWarning('HTTPS://DOCS.GOOGLE.COM/document/d/abc/edit'),
        isNotNull,
      );
      // A short Drive id cannot be rewritten, so that shape still warns.
      expect(
        mediaShareLinkWarning('HTTPS://DRIVE.GOOGLE.COM/file/d/abc/view'),
        isNotNull,
      );
    });

    test('Dropbox share links, but not its direct host', () {
      expect(
        mediaShareLinkWarning('https://www.dropbox.com/s/abc/pic.png?dl=0'),
        isNotNull,
      );
      // The direct-content host IS usable, so it must not be warned about.
      expect(
        mediaShareLinkWarning(
          'https://dl.dropboxusercontent.com/s/abc/pic.png',
        ),
        isNull,
      );
    });

    test('OneDrive and SharePoint image share links', () {
      expect(mediaShareLinkWarning('https://1drv.ms/i/s!Abc'), isNotNull);
      expect(
        mediaShareLinkWarning('https://onedrive.live.com/?id=abc'),
        isNotNull,
      );
      expect(
        mediaShareLinkWarning('https://acme.sharepoint.com/:i:/g/abc'),
        isNotNull,
      );
    });
  });

  group('it stays quiet for anything usable', () {
    test('an ordinary direct image or video URL', () {
      for (final String url in <String>[
        'https://cdn.example.com/plate.png',
        'https://cdn.example.com/clip.mp4',
        'https://storage.googleapis.com/bucket/plate.jpg',
        // Drive's own DIRECT form serves image/jpeg with CORS open - fragile
        // for an exam, but not the mistake this warning is about.
        // Drive's own direct forms, and the two hosts the rewrite targets.
        'https://drive.google.com/uc?export=view&id=1234567890abc',
        'https://lh3.googleusercontent.com/d/abc',
        'https://drive.usercontent.google.com/download?id=abc&export=view',
      ]) {
        expect(
          mediaShareLinkWarning(url),
          isNull,
          reason: '$url is usable and must not be warned about',
        );
      }
    });

    test("this app's own uploaded media path", () {
      expect(
        mediaShareLinkWarning('/api/v1/forms/media/abc123'),
        isNull,
      );
    });

    test('an empty or whitespace field says nothing', () {
      // Nothing typed yet is not a mistake.
      expect(mediaShareLinkWarning(''), isNull);
      expect(mediaShareLinkWarning('   '), isNull);
    });

    test('a SharePoint link that is not an image share is left alone', () {
      // Only the `:i:` (image) share shape is recognised; a plain site URL is
      // not something this warning knows anything about.
      expect(
        mediaShareLinkWarning('https://acme.sharepoint.com/sites/team'),
        isNull,
      );
    });
  });
}
