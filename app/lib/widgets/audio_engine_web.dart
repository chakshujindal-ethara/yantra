import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'audio_engine.dart';

AudioEngine create() => _WebAudioEngine();

class _WebAudioEngine implements AudioEngine {
  _WebAudioEngine() {
    _audio.preload = 'metadata';
    _listen('timeupdate', _time);
    _listen('durationchange', _time);
    _listen('ended', () => onEnded?.call());
    _listen('error', () => onError?.call('This audio could not be played. The link may have expired; reopen the unit.'));
  }

  final web.HTMLAudioElement _audio = web.HTMLAudioElement();
  final List<(String, JSFunction)> _listeners = [];

  void _listen(String type, void Function() f) {
    final js = ((web.Event _) => f()).toJS;
    _listeners.add((type, js));
    _audio.addEventListener(type, js);
  }

  void _time() {
    final d = _audio.duration;
    onTime?.call(_seconds(_audio.currentTime), d.isNaN || d.isInfinite ? Duration.zero : _seconds(d));
  }

  static Duration _seconds(num s) => Duration(milliseconds: (s * 1000).round());

  @override
  bool get supported => true;

  @override
  void load(String url) {
    _audio.src = url;
    _audio.load();
  }

  @override
  Future<void> play() async {
    try {
      await _audio.play().toDart;
    } on Object {
      onError?.call('This audio could not be played. The link may have expired; reopen the unit.');
    }
  }

  @override
  void pause() => _audio.pause();

  @override
  void seek(Duration to) => _audio.currentTime = to.inMilliseconds / 1000;

  @override
  void dispose() {
    _audio.pause();
    for (final (type, js) in _listeners) {
      _audio.removeEventListener(type, js);
    }
    _audio.src = '';
  }

  @override
  void Function(Duration position, Duration duration)? onTime;
  @override
  void Function()? onEnded;
  @override
  void Function(String message)? onError;
}
