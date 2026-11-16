import 'audio_engine_stub.dart' if (dart.library.js_interop) 'audio_engine_web.dart' as impl;

/// What the audio player needs from the platform: load a URL, play, pause, seek, and hear back the
/// position, the duration, the end and errors. The web one drives an `HTMLAudioElement` held in Dart (no
/// platform view, no plugin); elsewhere [supported] is false and the player says audio plays in the
/// browser.
abstract class AudioEngine {
  bool get supported;
  void load(String url);
  Future<void> play();
  void pause();
  void seek(Duration to);
  void dispose();

  /// Position and duration changes, end of playback, and load or playback errors.
  void Function(Duration position, Duration duration)? onTime;
  void Function()? onEnded;
  void Function(String message)? onError;
}

AudioEngine createAudioEngine() => impl.create();

/// The engine tests use: records what the player asked for and lets the test report time and errors.
class MemoryAudioEngine implements AudioEngine {
  MemoryAudioEngine({this.supported = true});

  @override
  final bool supported;
  final List<String> calls = [];

  @override
  void load(String url) => calls.add('load $url');
  @override
  Future<void> play() async => calls.add('play');
  @override
  void pause() => calls.add('pause');
  @override
  void seek(Duration to) => calls.add('seek ${to.inSeconds}');
  @override
  void dispose() => calls.add('dispose');

  @override
  void Function(Duration position, Duration duration)? onTime;
  @override
  void Function()? onEnded;
  @override
  void Function(String message)? onError;
}
