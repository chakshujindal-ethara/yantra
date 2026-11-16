import 'dart:async';

import 'package:flutter/widgets.dart';

/// Runs [tick] now and then every [every] while the tab is visible. A hidden tab (Flutter web maps the
/// browser's `visibilitychange` to [AppLifecycleState.hidden]) stops the timer; coming back ticks at
/// once when the last tick is older than [every], then resumes the cadence. Ticks never overlap. A tick
/// that throws never escapes: the first failure of a streak is logged and the cadence goes on (the page
/// shows its own "couldn't refresh" line when it cares).
class Poller with WidgetsBindingObserver {
  Poller({required this.every, required this.tick, DateTime Function()? clock, void Function(String)? log})
    : _clock = clock ?? DateTime.now,
      _log = log ?? debugPrint;

  final Duration every;
  final Future<void> Function() tick;
  final DateTime Function() _clock;
  final void Function(String) _log;
  bool _failing = false;

  Timer? _timer;
  DateTime? _last;
  bool _running = false;
  bool _hidden = false;
  bool _busy = false;

  bool get running => _running;

  void start() {
    if (_running) return;
    _running = true;
    WidgetsBinding.instance.addObserver(this);
    _schedule();
    unawaited(_run());
  }

  void stop() {
    if (!_running) return;
    _running = false;
    _timer?.cancel();
    _timer = null;
    WidgetsBinding.instance.removeObserver(this);
  }

  void dispose() => stop();

  void _schedule() {
    _timer?.cancel();
    _timer = Timer.periodic(every, (_) => unawaited(_run()));
  }

  Future<void> _run() async {
    if (_busy || _hidden || !_running) return;
    _busy = true;
    _last = _clock();
    try {
      await tick();
      _failing = false;
    } on Object catch (e) {
      if (!_failing) _log('Poller: a refresh failed, still polling every ${every.inSeconds}s: $e');
      _failing = true;
    } finally {
      _busy = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_running) return;
    switch (state) {
      case AppLifecycleState.hidden || AppLifecycleState.paused || AppLifecycleState.detached:
        _hidden = true;
        _timer?.cancel();
        _timer = null;
      case AppLifecycleState.resumed:
        if (!_hidden) return;
        _hidden = false;
        final last = _last;
        if (last == null || _clock().difference(last) >= every) unawaited(_run());
        _schedule();
      case AppLifecycleState.inactive:
        break;
    }
  }
}
