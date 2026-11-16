// WHAT KIND OF MEDIA IS AT THIS URL - the question four places used to answer
// differently, and all four got the same two shapes wrong.
//
// THE DEFECT. Every copy tested the extension of the WHOLE url string:
// `_looksImage` in the designer, `_looksVideoUrl` in the preview, an inline
// copy in the preview's A/B tiles, and `_looks_like_video` on the server. So:
//
//   * a YouTube or Vimeo link has no extension, and was called an IMAGE. It
//     went to `Image.network`, which mounts an element with nothing to decode -
//     a dead plate, no error, no explanation. `VideoPlate` could already embed
//     both hosts perfectly well; only `videoBlock` ever reached it.
//   * `https://cdn.example.com/clip.mp4?sig=abc` hides its extension behind the
//     query string every signed CDN URL carries, and was called an image too.
//
// The server copy made it worse than cosmetic: a YouTube URL filed under
// `images` was FETCHED at publish, and ~1MB of YouTube HTML was stored as the
// question's image with no warning to anybody.
//
// These tests pin the classifier all four now share. The image DEFAULT is
// pinned too: our own proxy paths carry no extension and are stills.
@TestOn('vm')
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/screens/exam/video_plate.dart';

void main() {
  group('a hosted player link is a video, not a picture', () {
    for (final String url in <String>[
      'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
      'https://youtube.com/watch?v=dQw4w9WgXcQ',
      'https://youtu.be/dQw4w9WgXcQ',
      'https://www.youtube.com/embed/dQw4w9WgXcQ',
      'https://www.youtube.com/shorts/dQw4w9WgXcQ',
      'https://vimeo.com/123456789',
      'https://player.vimeo.com/video/123456789',
    ]) {
      test('$url embeds', () {
        expect(mediaKindOf(url), MediaKind.embeddedVideo);
        expect(isVideoMedia(url), isTrue);
      });
    }

    // A host we cannot embed is not thereby a picture - but it is also not
    // something `publicVideoEmbedRef` can mount, so it falls to the default.
    test('a youtube URL with no video id is not an embed', () {
      expect(mediaKindOf('https://www.youtube.com/feed/subscriptions'),
          MediaKind.image);
    });
  });

  group('a direct clip is a video whatever follows the extension', () {
    for (final String url in <String>[
      'https://cdn.example.com/clip.mp4',
      // THE SIGNED-CDN SHAPE. Every one of these was classified as an image.
      'https://cdn.example.com/clip.mp4?sig=abc&expires=123',
      'https://cdn.example.com/clip.webm?v=2',
      'https://cdn.example.com/clip.MOV',
      'https://cdn.example.com/clip.mp4#t=10',
      '/api/v1/forms/media/form_studio/deadbeef.mp4',
    ]) {
      test('$url plays', () {
        expect(mediaKindOf(url), MediaKind.videoFile);
        expect(isVideoMedia(url), isTrue);
      });
    }
  });

  group('everything else is a still', () {
    for (final String url in <String>[
      'https://cdn.example.com/plate.png',
      'https://cdn.example.com/plate.jpg?w=800',
      'https://storage.googleapis.com/bucket/plate.jpeg',
      // Our own uploads: a real extension, but the point is they are stills.
      '/api/v1/forms/media/form_studio/deadbeef.png',
      // A Drive direct link carries no extension at all.
      'https://drive.google.com/uc?export=view&id=abc',
      // An admin proxy path, which never carries one either.
      '/assessments_be/admin_qimage/42',
    ]) {
      test('$url draws as an image', () {
        expect(mediaKindOf(url), MediaKind.image);
        expect(isVideoMedia(url), isFalse);
      });
    }

    test('an empty or unparseable value does not throw', () {
      expect(mediaKindOf(''), MediaKind.image);
      expect(mediaKindOf('   '), MediaKind.image);
      expect(mediaKindOf('not a url at all'), MediaKind.image);
      // `.mp4` still wins on a bare filename - the server's own test is the
      // extension of the path, and an unparseable string IS its own path.
      expect(mediaKindOf('clip.mp4'), MediaKind.videoFile);
    });
  });

  // The lookalike-host discipline the server's importer tests spell out, held
  // here too: this decides whether publish tries to DOWNLOAD a URL, so a
  // substring match on 'youtube.com' would be a real mistake and not only an
  // untidy one.
  group('an embed host is matched as a whole host', () {
    for (final String url in <String>[
      'https://youtube.com.evil.test/watch?v=abc',
      'https://evil.test/?u=https://youtube.com/watch?v=abc',
      'https://notvimeo.com/123456789',
    ]) {
      test('$url is not treated as an embed', () {
        expect(mediaKindOf(url), isNot(MediaKind.embeddedVideo));
      });
    }
  });
}
