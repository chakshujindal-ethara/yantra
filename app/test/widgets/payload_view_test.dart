import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yantra_app/core/theme/app_theme.dart';
import 'package:yantra_app/widgets/audio_engine.dart';
import 'package:yantra_app/widgets/audio_player.dart';
import 'package:yantra_app/widgets/payload_view.dart';

Widget host(Widget child) => MaterialApp(
  theme: AppTheme.light,
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

void main() {
  test('each value is read for what it is', () {
    expect(PayloadView.kindOf('audio_ref', 's3://yantra/projects/p/u/a.wav'), PayloadKind.audio);
    expect(PayloadView.kindOf('speaker_audio', 'x'), PayloadKind.audio);
    expect(PayloadView.kindOf('clip', 'projects/p/units/u/a.mp3'), PayloadKind.audio);
    expect(PayloadView.kindOf('image_url', 'https://x/y'), PayloadKind.image);
    expect(PayloadView.kindOf('photo', 'https://cdn/a.jpg'), PayloadKind.image);
    expect(PayloadView.kindOf('photo', 'projects/p/units/u/a.png'), PayloadKind.image);
    expect(PayloadView.kindOf('prompt', 'Translate this'), PayloadKind.prose);
    expect(PayloadView.kindOf('notes', 'x' * 121), PayloadKind.prose);
    expect(PayloadView.kindOf('language', 'hi'), PayloadKind.row);
    expect(PayloadView.kindOf('count', 3), PayloadKind.row);
  });

  testWidgets('an audio ref with a media link becomes a player; without one it stays text', (tester) async {
    await tester.pumpWidget(
      host(
        PayloadView(const {'audio_ref': 's3://yantra/projects/p/units/u/a.wav', 'language': 'hi'}, mediaUrl: () async => 'http://minio/a'),
      ),
    );
    expect(find.byKey(const Key('payload-audio-audio_ref')), findsOneWidget);
    expect(find.byKey(const Key('audio-unsupported')), findsOneWidget, reason: 'off the web the player says audio plays in the browser');
    expect(find.text('hi'), findsOneWidget);
    await tester.pumpWidget(host(const PayloadView({'audio_ref': 's3://yantra/x.wav'})));
    expect(find.byKey(const Key('payload-audio-audio_ref')), findsNothing);
    expect(find.text('s3://yantra/x.wav'), findsOneWidget);
  });

  testWidgets('prose and images; a stored image without a link stays text; an empty payload says so', (tester) async {
    await tester.pumpWidget(
      host(
        PayloadView(const {
          'prompt': 'Say it plainly',
          'image_ref': 'projects/p/units/u/a.png',
        }, mediaUrl: () async => throw StateError('gone')),
      ),
    );
    await tester.pump();
    expect(find.byKey(const Key('payload-prose-prompt')), findsOneWidget);
    expect(find.text('The image could not be loaded.'), findsOneWidget);
    await tester.pumpWidget(host(const PayloadView({'image_ref': 'projects/p/units/u/a.png'})));
    expect(find.text('projects/p/units/u/a.png'), findsOneWidget);
    await tester.pumpWidget(host(const PayloadView({})));
    expect(find.text('(empty payload)'), findsOneWidget);
    await tester.pumpWidget(host(PayloadView(const {'image_url': 'https://cdn/a.png'}, mediaUrl: () async => 'x')));
    expect(find.byKey(const Key('payload-image-image_url')), findsOneWidget);
    await tester.pumpAndSettle();
  });

  testWidgets('the answer view: prose for long text, Yes/No for flags, rows for the rest', (tester) async {
    await tester.pumpWidget(host(AnswerView({'transcript': 'line one\nline two', 'speakers': 2, 'noisy': true})));
    expect(find.byKey(const Key('answer-prose-transcript')), findsOneWidget);
    expect(find.text('Yes'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    await tester.pumpWidget(host(const AnswerView({})));
    expect(find.text('(empty answer)'), findsOneWidget);
  });

  testWidgets('the player fetches the link on the first play, pauses, seeks, ends, and refetches after an error', (tester) async {
    final engine = MemoryAudioEngine();
    var fetched = 0;
    await tester.pumpWidget(
      host(
        AudioPlayer(
          url: () async {
            fetched++;
            return 'http://minio/a$fetched';
          },
          engine: engine,
        ),
      ),
    );
    expect(find.text('0:00 / 0:00'), findsOneWidget);
    await tester.tap(find.byKey(const Key('audio-play')));
    await tester.pump();
    expect(engine.calls, ['load http://minio/a1', 'play']);
    engine.onTime!(const Duration(seconds: 5), const Duration(seconds: 65));
    await tester.pump();
    expect(find.text('0:05 / 1:05'), findsOneWidget);
    await tester.tap(find.byKey(const Key('audio-play')));
    await tester.pump();
    expect(engine.calls.last, 'pause');
    await tester.drag(find.byKey(const Key('audio-seek')), const Offset(200, 0));
    expect(engine.calls.last, startsWith('seek'));
    engine.onEnded!();
    engine.onError!('This audio could not be played.');
    await tester.pump();
    expect(find.byKey(const Key('audio-error')), findsOneWidget);
    await tester.tap(find.byKey(const Key('audio-play')));
    await tester.pump();
    expect(fetched, 2, reason: 'after an error the next play asks for a fresh link');
    await tester.pumpWidget(const SizedBox());
    expect(engine.calls.last, 'dispose');
  });

  testWidgets('a link that cannot be fetched shows why and plays nothing', (tester) async {
    final engine = MemoryAudioEngine();
    await tester.pumpWidget(host(AudioPlayer(url: () async => throw StateError('no'), engine: engine)));
    await tester.tap(find.byKey(const Key('audio-play')));
    await tester.pump();
    expect(find.byKey(const Key('audio-error')), findsOneWidget);
    expect(engine.calls, isEmpty);
  });
}
