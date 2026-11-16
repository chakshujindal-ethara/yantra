// AN AUDIO CLIP GETS AN AUDIO PLAYER, in the exam and in the designer.
//
// Form Studio can now carry an mp3/wav/m4a/ogg/aac/flac in a `videoBlock`. The
// server publishes it on `question.video` and tags the candidate's `videos[]`
// entry `kind: "audio"`. Handed to the video plate it would mount a `<video>`
// over bytes with no picture - a black rectangle with working sound controls at
// best - so the one place that picks a plate (`clipPlateFor`) must send audio to
// `AudioPlate` and everything else to `VideoPlate`.
//
// TWO SIGNALS, because a candidate clip url is a token path
// (`/assessments_be/exam/qvideo/<token>/<id>`) with no extension to read: the
// server's `kind` wins, and the extension decides everywhere that has no `kind`
// (the designer, a pasted link, an older server).
//
// On the VM `VideoPlate` is the stub, which draws `MissingVideo`, and
// `AudioPlate` is its own stub: "which plate was chosen" is exactly what these
// can assert. The browser's `<audio>` element is not reachable here.
@TestOn('vm')
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/domain/form_models.dart';
import 'package:ethara_assessment/assessment/domain/models.dart';
import 'package:ethara_assessment/assessment/screens/admin/form_item_editor.dart';
import 'package:ethara_assessment/assessment/screens/exam/answer_layouts.dart';
import 'package:ethara_assessment/assessment/screens/exam/audio_plate.dart';
import 'package:ethara_assessment/assessment/screens/exam/video_plate.dart';
import 'package:ethara_assessment/assessment/state/app_store.dart';
import 'package:ethara_assessment/services/file_pick_stub.dart';

const List<String> _audioNames = <String>[
  'clip.mp3',
  'clip.wav',
  'clip.m4a',
  'clip.ogg',
  'clip.aac',
  'clip.flac',
];

/// What a candidate's `videos[]` entry looks like: a token path, no extension.
const String _candidatePath = '/assessments_be/exam/qvideo/tok123/9';

Future<void> _pumpAll(WidgetTester tester, List<Widget> plates) async {
  tester.view.physicalSize = const Size(1000, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(child: Column(children: plates)),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _pumpEditor(
  WidgetTester tester, {
  required String mediaUrl,
  FormItemKind kind = FormItemKind.videoBlock,
  String mediaKind = '',
}) async {
  tester.view.physicalSize = const Size(1400, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final FormItem item = FormItem('item-1', kind, title: 'Listen to this')
    ..mediaUrl = mediaUrl
    ..mediaKind = mediaKind;

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
  group('the kind is read off the extension when the server did not say', () {
    test('every accepted audio extension is audio', () {
      for (final String n in _audioNames) {
        expect(mediaKindOf('https://cdn.example.com/$n'), MediaKind.audio,
            reason: n);
        expect(isVideoMedia('https://cdn.example.com/$n'), isTrue,
            reason: '$n belongs in a player, not an image tag');
      }
    });

    test('a signed url and an upper-case name are still audio', () {
      expect(mediaKindOf('https://cdn.example.com/Clip.MP3?sig=abc'),
          MediaKind.audio);
      expect(mediaKindOf('/api/v1/forms/media/form_studio/u1/a.m4a'),
          MediaKind.audio);
    });

    test('a video and a still keep their kinds', () {
      expect(mediaKindOf('https://cdn.example.com/a.mp4'), MediaKind.videoFile);
      expect(mediaKindOf('https://cdn.example.com/a.mov'), MediaKind.videoFile);
      expect(mediaKindOf('https://cdn.example.com/a.png'), MediaKind.image);
      expect(
        mediaKindOf('https://www.youtube.com/watch?v=dQw4w9WgXcQ'),
        MediaKind.embeddedVideo,
      );
    });
  });

  group('the server kind wins, and is parsed off the clip asset', () {
    test('kind "audio" on an extensionless candidate url is audio', () {
      final Asset a = Asset.fromJson(<String, dynamic>{
        'id': 9,
        'label': 'Listen',
        'url': _candidatePath,
        'kind': 'audio',
      });
      expect(a.kind, 'audio');
      expect(mediaKindOfAsset(a), MediaKind.audio);
    });

    test('with no kind (an older server) the extension decides', () {
      final Asset mp3 = Asset.fromJson(<String, dynamic>{
        'id': 1,
        'label': 'x',
        'url': 'https://cdn.example.com/a.mp3',
      });
      expect(mp3.kind, isNull);
      expect(mediaKindOfAsset(mp3), MediaKind.audio);

      final Asset mp4 = Asset.fromJson(<String, dynamic>{
        'id': 2,
        'label': 'x',
        'url': 'https://cdn.example.com/a.mp4',
        'kind': 'video',
      });
      expect(mediaKindOfAsset(mp4), MediaKind.videoFile);
    });

    test('Odoo\'s false for an unset Char is no kind at all', () {
      final Asset a = Asset.fromJson(<String, dynamic>{
        'id': 3,
        'label': 'x',
        'url': 'https://cdn.example.com/a.mp4',
        'kind': false,
      });
      expect(a.kind, isNull);
      expect(a.toJson().containsKey('kind'), isFalse);
    });

    test('copyWith and toJson carry the kind', () {
      const Asset a = Asset(id: '1', label: 'x', url: '/p', kind: 'audio');
      expect(a.copyWith(url: '/q').kind, 'audio');
      expect(a.toJson()['kind'], 'audio');
    });
  });

  group('the exam picks the plate', () {
    testWidgets('an audio clip gets the AudioPlate, never the VideoPlate', (
      WidgetTester tester,
    ) async {
      await _pumpAll(tester, <Widget>[
        clipPlateFor(
          const Asset(
            id: '9',
            label: 'Listen',
            url: _candidatePath,
            kind: 'audio',
          ),
          caption: 'Listen to the call',
        ),
      ]);

      expect(find.byType(AudioPlate), findsOneWidget);
      expect(find.byType(VideoPlate), findsNothing);
      expect(find.byType(MissingVideo), findsNothing);
      expect(find.text('Listen to the call'), findsOneWidget);
    });

    testWidgets('a video clip still gets the VideoPlate', (
      WidgetTester tester,
    ) async {
      await _pumpAll(tester, <Widget>[
        clipPlateFor(
          const Asset(
            id: '8',
            label: 'Watch',
            url: _candidatePath,
            kind: 'video',
          ),
        ),
      ]);

      expect(find.byType(VideoPlate), findsOneWidget);
      expect(find.byType(AudioPlate), findsNothing);
    });

    testWidgets('the question\'s plates mix both, each on its own player', (
      WidgetTester tester,
    ) async {
      // `mediaPlates` is what the exam's stimulus and the post-release answer
      // sheet both render, so this is the candidate-facing path.
      await _pumpAll(
        tester,
        mediaPlates(
          const <Asset>[],
          const <Asset>[
            Asset(id: '1', label: 'Reference', url: _candidatePath, kind: 'audio'),
            Asset(id: '2', label: 'Output', url: _candidatePath, kind: 'video'),
          ],
        ),
      );

      expect(find.byType(AudioPlate), findsOneWidget);
      expect(find.byType(VideoPlate), findsOneWidget);
    });
  });

  group('the designer accepts and previews audio', () {
    test('the picker offers every audio extension and uploads the right MIME',
        () {
      for (final String n in _audioNames) {
        expect(kFormAudioAccept, contains(n.substring(n.indexOf('.'))),
            reason: '$n is not offered by the file picker');
      }
      expect(formMediaContentType('clip.mp3'), 'audio/mpeg');
      expect(formMediaContentType('Clip.WAV'), 'audio/wav');
      expect(formMediaContentType('clip.m4a'), 'audio/mp4');
      expect(formMediaContentType('clip.ogg'), 'audio/ogg');
      expect(formMediaContentType('clip.aac'), 'audio/aac');
      expect(formMediaContentType('clip.flac'), 'audio/flac');
      // Untouched: the video and image types the signed policy already matched.
      expect(formMediaContentType('clip.mp4'), 'video/mp4');
      expect(formMediaContentType('clip.mov'), 'video/quicktime');
      expect(formMediaContentType('a.png'), 'image/png');
    });

    test('the kind reads Video and keeps its wire string', () {
      expect(FormItemKind.videoBlock.label, 'Video');
      expect(FormItemKind.videoBlock.name, 'videoBlock');
    });

    testWidgets('a videoBlock holding an mp3 previews on the AudioPlate', (
      WidgetTester tester,
    ) async {
      await _pumpEditor(
        tester,
        mediaUrl: '/api/v1/forms/media/form_studio/u1/clip.mp3',
      );

      expect(find.byType(AudioPlate), findsOneWidget);
      expect(find.byType(MissingVideo), findsNothing);
    });

    testWidgets('a videoBlock holding an mp4 still previews on the VideoPlate', (
      WidgetTester tester,
    ) async {
      await _pumpEditor(
        tester,
        mediaUrl: '/api/v1/forms/media/form_studio/u1/clip.mp4',
      );

      expect(find.byType(MissingVideo), findsOneWidget);
      expect(find.byType(AudioPlate), findsNothing);
    });

    testWidgets('a videoBlock with an extensionless url is still a video', (
      WidgetTester tester,
    ) async {
      await _pumpEditor(tester, mediaUrl: 'https://example.com/stream/abc');

      expect(find.byType(MissingVideo), findsOneWidget);
      expect(find.byType(AudioPlate), findsNothing);
    });

    // THROUGH THE EDITOR, not the constant: this is what the file chooser is
    // actually given, so un-wiring the Audio block's picker fails it.
    testWidgets('the Audio block picker is handed .mp3; an imageBlock one is not',
        (WidgetTester tester) async {
      final List<String> accepts = <String>[];
      FormItemEditor.pick = ({String accept = ''}) async {
        accepts.add(accept);
        return null;
      };
      addTearDown(() => FormItemEditor.pick = pickFile);

      Future<String> acceptFor(FormItemKind kind, {String mediaKind = ''}) async {
        accepts.clear();
        await _pumpEditor(tester, mediaUrl: '', kind: kind, mediaKind: mediaKind);
        await tester.tap(find.text('Upload'));
        await tester.pump();
        await tester.tap(find.text('Choose a file'));
        await tester.pump();
        return accepts.single;
      }

      final String audio =
          await acceptFor(FormItemKind.videoBlock, mediaKind: 'audio');
      for (final String n in _audioNames) {
        expect(audio, contains(n.substring(n.indexOf('.'))), reason: n);
      }
      expect(audio, isNot(contains('.mp4')), reason: 'Video is its own block');

      final String image = await acceptFor(FormItemKind.imageBlock);
      expect(image, isNot(contains('.mp3')));
      expect(image, contains('.png'));
    });
  });

  group('the audio plate names the clip', () {
    const Asset labelled = Asset(
      id: '9',
      label: 'Customer call',
      url: _candidatePath,
      kind: 'audio',
    );

    test('caption, then label, then the file name, then the generic words', () {
      expect(audioClipName(labelled, 'Listen first'), 'Listen first');
      expect(audioClipName(labelled, ''), 'Customer call');
      expect(
        audioClipName(
          const Asset(
            id: '1',
            label: '',
            url: '/api/v1/forms/media/form_studio/u1/call.mp3',
          ),
          '',
        ),
        'call.mp3',
      );
      // A copied link is stored under a hex key - not a name either.
      expect(
        audioClipName(
          const Asset(
            id: '1',
            label: '',
            url:
                '/api/v1/forms/media/form_studio/cdb07397fc90462bb578589ecacda23f.mp3',
          ),
          '',
        ),
        'Audio clip',
      );
      // A candidate token path ends in a bare id - not a name worth printing.
      expect(
        audioClipName(
          const Asset(id: '1', label: '  ', url: _candidatePath, kind: 'audio'),
          '',
        ),
        'Audio clip',
      );
    });

    testWidgets('a label that only repeats the prompt is not printed again', (
      WidgetTester tester,
    ) async {
      // The exam blanks such a caption; the audio plate used to fall back to
      // the same label and print the question a second time.
      await _pumpAll(
        tester,
        mediaPlates(const <Asset>[], <Asset>[labelled], echoes: 'Customer call.'),
      );

      expect(find.text('Customer call'), findsNothing);
      expect(find.text('Audio clip'), findsOneWidget);
    });

    testWidgets('with no caption the plate prints the asset label', (
      WidgetTester tester,
    ) async {
      await _pumpAll(tester, <Widget>[clipPlateFor(labelled)]);

      expect(find.byType(AudioPlate), findsOneWidget);
      expect(find.text('Customer call'), findsOneWidget);
      expect(find.text('Audio clip'), findsNothing);
    });
  });
}
